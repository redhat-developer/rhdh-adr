# ADR-013: Route-based deferred loading for dynamic frontend plugins

## Context

**Problem**: The `dynamicFrontendFeaturesLoader` in the New Frontend System (NFS) eagerly loads all dynamic frontend plugins at startup via Module Federation, regardless of which page the user visits.

**Lighthouse Performance Report** (RHDH on OpenShift cluster, `/intelligent-assistant` page, 16-18 dynamic plugins):

| Metric | Value |
|--------|-------|
| Performance Score | 55/100 |
| First Contentful Paint (FCP) | 6.0s |
| Largest Contentful Paint (LCP) | 13.9s |
| Speed Index | 10.7s |
| Total Payload | ~6.5 MB |

With just 16-18 dynamic plugins, LCP is already 13.9s. Production deployments targeting 40-80+ plugins will scale linearly worse. Visiting `/intelligent-assistant` should not require downloading and executing code for every other plugin in the system.

The current loader iterates every remote unconditionally:

```javascript
const features = (await Promise.all(
  frontendPluginRemotes.map(async (remote) => {
    const moduleFeatures = await Promise.all(
      remote.exposedModules.map(async (exposedModuleName) => {
        module = await instance.loadRemote(remoteModuleName);
      })
    );
    return moduleFeatures;
  })
)).flat();
return [...features];
```

An upstream RFC has been filed at `https://github.com/backstage/backstage/issues/35037`. This ADR documents the RHDH-specific fallback approach if the upstream RFC is delayed or not accepted.

## Decision

Implement `rhdhDynamicFeaturesLoader` in `packages/app-next/src/` that replaces the upstream `dynamicFrontendFeaturesLoader` with route-aware deferred loading logic.

### 1. `backstage.routes` metadata in plugin `package.json`

**Goal:** Enable the loader to determine — *before downloading any plugin code* — whether a plugin should be loaded immediately at startup or deferred until the user navigates to a specific path.

Today, the only way to know a plugin's route is to load its JavaScript bundle, instantiate its `PageBlueprint`, and inspect the `path` parameter. This creates a chicken-and-egg problem: you must load the plugin to know if you need it, which defeats the purpose of lazy loading.

By adding route metadata to `package.json`, the backend remotes endpoint (which already serves plugin metadata like `pluginId`, `role`, and `features`) can include route information in its response. The frontend loader then classifies every plugin **using only this lightweight JSON metadata** — no JavaScript execution required.

**The complete approach** would be to introduce `backstage.routes` for every plugin:

For page plugins (loaded only when user navigates to their path):
```json
{
  "backstage": {
    "routes": {
      "page:techdocs": { "path": "/docs" }
    }
  }
}
```

For plugins consumed across the entire app, not at any particular path:
```json
{
  "backstage": {
    "routes": { "path": "*" }
  }
}
```

However, this would require editing **100-200+ plugins** across `backstage/backstage`, `backstage/community-plugins`, and `redhat-developer/rhdh-plugins` — which is impractical.

**The optimization:** If we look at the `pluginId` and the registered `path` across all existing page plugins, a clear pattern emerges — the vast majority route at `/<pluginId>`:

- `@backstage/plugin-catalog` → `/catalog`
- `@backstage/plugin-search` → `/search`
- `@backstage/plugin-notifications` → `/notifications`
- `@backstage-community/plugin-rbac` → `/rbac`
- `@backstage-community/plugin-lighthouse` → `/lighthouse`
- `@backstage-community/plugin-tech-radar` → `/tech-radar`
- `@red-hat-developer-hub/backstage-plugin-adoption-insights` → `/adoption-insights`
- `@red-hat-developer-hub/backstage-plugin-orchestrator` → `/orchestrator`

Since the `pluginId` is already available in the remotes metadata, the loader can **infer** the path as `/<pluginId>` without any `package.json` change.

This means we only need to add `backstage.routes` for plugins that are exceptions:
1. Plugins routed at a **non-conventional path** (does not load at `/<pluginId>`)
2. Plugins **consumed across the app** (does not load at any specific path)

This reduces the required changes from ~100-200 plugins to only **~5-8 exceptions**.

### 2. Plugins that need explicit metadata

**Plugins at non-standard paths (need `backstage.routes`):**

| Source | Plugin | pluginId | Actual Path |
|--------|--------|----------|-------------|
| backstage | techdocs | techdocs | /docs |
| backstage | scaffolder | scaffolder | /create |
| backstage | user-settings | user-settings | /settings |
| backstage | home | home | /home |
| community-plugins | azure-devops | azure-devops | /azure-pull-requests |

**App-wide plugins (need `"path": "*"`):**

| Source | Plugin | pluginId | Reason |
|--------|--------|----------|--------|
| rhdh-plugins | global-header | global-header | AppRootWrapperBlueprint, wraps entire app |
| rhdh-plugins | homepage | homepage | API-only, no page |
| backstage | signals | signals | WebSocket API provider |

All other page plugins follow the `/<pluginId>` convention and need zero changes.

### 3. Operator escape hatches (for plugins not yet updated)

There will be cases where a plugin author hasn't yet added `backstage.routes` to their `package.json`. This could happen because:
- The plugin is maintained by a third party and changes haven't been merged yet
- The plugin is in a repo the operator doesn't control
- The operator is running an older version of a plugin that predates this feature

In these cases, the operator (the person deploying and configuring RHDH) needs a way to correct the loader's behavior from their `app-config.yaml` — without touching plugin source code.

**Case 1: Plugin at a non-conventional path (does not load at `/<pluginId>`) that hasn't added `backstage.routes`**

Without any signal, the loader would assume the plugin lives at `/<pluginId>`. For example, `techdocs` (pluginId: `techdocs`) would be deferred to `/techdocs` — but it actually registers at `/docs`. The user visits `/docs`, nothing loads. The user visits `/techdocs`, the plugin loads but the route doesn't match.

The existing NFS `app.extensions` config already supports overriding the `path` of any page extension (`PageBlueprint.configSchema` declares `path: z.string().optional()`). The loader can read this same config to determine the correct deferred path:

```yaml
app:
  extensions:
    - page:techdocs:
        config:
          path: /docs
```

This tells the loader: "defer `techdocs` until the user navigates to `/docs`." No new config schema is introduced — this reuses an existing NFS mechanism that operators may already be using for other purposes (like customizing page titles).

**Case 2: App-wide plugin (does not load at any specific path) that hasn't added `"path": "*"`**

Without any signal, the loader would assume the plugin is a page plugin and defer it to `/<pluginId>`. For example, `signals` (pluginId: `signals`) would be deferred to `/signals`. But `signals` is an API-only plugin that provides a WebSocket connection used by other plugins (like `notifications`) on every page. Deferring it would break real-time features across the entire app.

A minimal new config key allows the operator to force specific plugins to load eagerly:

```yaml
dynamicPlugins:
  loading:
    eager:
      - signals
      - global-header
```

This tells the loader: "load these plugins immediately at startup regardless of route metadata."

### 4. Priority chain

The loader uses this priority chain to classify each plugin:

```
1. dynamicPlugins.loading.eager (app-config)         → eager (operator override)
2. app.extensions page:<id> config.path (app-config)  → defer to path (already exists in NFS)
3. backstage.routes in package.json (plugin metadata) → defer or eager per declaration
4. Convention /<pluginId> (automatic)                 → defer to default path
```

### 5. Entity-content plugins (no action needed)

Plugins that attach as entity tabs (e.g., `@backstage-community/plugin-topology`, `@backstage/plugin-kubernetes` entity tab) use `EntityContentBlueprint` which already wraps its component in `ExtensionBoundary.lazy()`. These are `createFrontendModule` extending the `catalog` plugin — they don't own a route themselves and their rendering is already lazy.

### 6. Implementation approach

- Create `rhdhDynamicFeaturesLoader` in `packages/app-next/src/` with classification + deferred loading
- Extend RHDH's `nfsModuleFilter.ts` backend to serve `backstage.routes` in the remotes response
- Add `backstage.routes` to the few exception plugins in `rhdh-plugins`
- Add `dynamicPlugins.loading.eager` config schema to `config.d.ts`

## Alternatives Considered

### Alternative 1: Require `backstage.routes` in all plugins
- **Approach**: Every plugin adds explicit route metadata to `package.json`
- **Rejected because**: Requires editing 100-200+ plugins across three repos. The convention-based approach achieves the same result with ~5-8 changes.

### Alternative 2: Wait for upstream acceptance only
- **Approach**: Depend entirely on the upstream RFC (`https://github.com/backstage/backstage/issues/35037`) being accepted and implemented
- **Rejected because**: Upstream timeline is uncertain. RHDH needs the performance improvement regardless. The `rhdhDynamicFeaturesLoader` can be deprecated once upstream ships.


## Consequences

### Positive
- ✅ Initial page load fetches only plugins relevant to the current route instead of all 16-18+ registered plugins
- ✅ Significant LCP/TTI reduction proportional to the number of deferred plugins
- ✅ No breaking changes — backward compatible with existing deployments
- ✅ Most plugins need zero changes (convention-based)
- ✅ Solution aligns with upstream RFC — can be deprecated when upstream ships

### Negative
- ❌ Introduces RHDH-specific loader code that must be maintained until upstream ships
- ❌ ~5-8 plugins need `backstage.routes` metadata added to their `package.json`
- ❌ New config key (`dynamicPlugins.loading.eager`) adds surface area

### Neutral
- ⚖️ If upstream RFC is accepted, `rhdhDynamicFeaturesLoader` becomes a no-op wrapper or is removed
- ⚖️ Entity-content plugins are unaffected — they already use `ExtensionBoundary.lazy()` internally
