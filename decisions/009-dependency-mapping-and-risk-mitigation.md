# ADR: Dependency Mapping and Risk Mitigation for RHDH Critical Components

## Context

**Problem**: The RHDH product is distributed across 12 interconnected repositories with no formal dependency map, no visibility into coupling strength, and no systematic understanding of which components are fragile or where a small change is most likely to cascade into a production incident.

The RHDH ecosystem has grown organically from a single Backstage fork into a multi-repo product spanning the full lifecycle: source code, plugin packaging, Helm charts, a Kubernetes operator, E2E test utilities, diagnostic tooling, local development environments, downstream productization, and architectural governance. Each repository has its own maintainers, release cadence, and CI/CD pipelines, but the inter-repo dependencies have never been systematically catalogued or assessed for risk.

This matters now because:

- **The plugin lifecycle chain has grown to 8 serial links.** A plugin goes from source code (`rhdh-plugins`) through export tooling (`rhdh-cli plugin export` + `plugin package`, `rhdh-plugin-export-utils`, `rhdh-plugin-export-overlays`) to individual plugin OCI images, then through catalog index generation (`generateCatalogIndex.py` in `rhdh-plugin-export-overlays` upstream, and the separate `rhdh-plugin-catalog` repo downstream on GitLab) to produce the `plugin-catalog-index` OCI image, then through deployment configuration (`rhdh-chart`, `rhdh-operator`) and finally through runtime installation (`cli-module-install-dynamic-plugins`) before it is available in a running RHDH instance. A break at any link stops delivery.

- **Cross-repo coupling is invisible.** Repositories reference each other through container image tags, npm package versions, Helm chart artifacts, raw GitHub URL downloads, and CI workflow calls at `@main` — but none of this is documented. A rename, a deleted file, or a bad push to `main` can silently break a downstream repo's CI or deployment.

- **The dynamic plugin installer recently migrated from Python to TypeScript** (RHDH 1.10+), moving from a self-contained script in the `rhdh` image to a cross-repo npm dependency on `rhdh-plugins`. This added a new hard dependency at the most critical runtime junction — init container startup.

- **The plugin catalog index adds a hidden link in the chain.** Between individual plugin OCI images being published and the deployment configuration referencing them, a `generateCatalogIndex.py` pipeline runs (in `rhdh-plugin-export-overlays` upstream, and in the separate `rhdh-plugin-catalog` GitLab repo downstream) to produce a `plugin-catalog-index` OCI image. This image contains the `dynamic-plugins.default.yaml` and marketplace metadata that the init container reads at pod startup. The downstream GitLab repo (`gitlab.cee.redhat.com/rhidp/rhdh-plugin-catalog`) is outside the GitHub-based dependency graph, creating a visibility gap.

- **Velocity is accelerating unevenly.** Some repos doubled their commit rate in the last quarter (`rhdh-plugin-export-overlays` +100%, `rhdh-chart` +244%, `rhdh-must-gather` +87%) while others are declining (`rhdh-cli` -50%). Accelerating churn on components that others depend on increases breakage probability; declining velocity on depended-upon components creates maintenance debt.

**Who is impacted**:
- **All RHDH developers**: Changes in one repo can break CI, builds, or deployments in another repo without any local signal
- **Release engineering**: The downstream sync and productization pipeline (`rhidp/Red Hat Developer Hub` (midstream)) depends on 7 upstream repos; a break in any one blocks the product release
- **Support teams**: If diagnostic tooling (`rhdh-must-gather`) regresses, customer support capacity is degraded
- **End users**: The dynamic plugin installer is the final gate before plugins are available at runtime; a regression means a blank RHDH instance with no plugins

**Constraints**:
- The multi-repo structure exists for good reasons (separation of concerns, different languages, different release cadences) and consolidation is only practical for a few cases
- Any mitigation must work within existing GitHub-based CI/CD workflows
- Mitigations should be incremental — no big-bang reorganization

## Decision

Adopt **systematic dependency mapping and risk-based prioritization** as an ongoing practice for the RHDH ecosystem. This means: (1) maintaining a documented dependency map between repositories, (2) using git history analysis to identify churn hotspots, (3) cross-referencing dependency fan-in with churn to find fragile components, and (4) prioritizing hardening work on the highest-risk areas first.

The core principle is: **components that change frequently and that many other components depend on are the most fragile.** High churn means more opportunities for breakage; high fan-in means breakage propagates widely. The combination identifies where a small change is most likely to cascade into a production incident.

**Implementation approach**:

### 1. Dependency Map (maintain as a living artifact)

The following dependency edges were identified through exhaustive analysis of all 12 repositories. Each edge is classified by coupling strength:

- **HARD**: Build or runtime breaks if the target changes (image references, npm imports, CI workflow calls)
- **SOFT**: CI or tests break but the product still functions (test utilities, documentation sync)
- **REFERENCE**: Documentation links only, no functional coupling

**Core dependency fan-in** (number of repos with HARD dependencies on each target):

| Target Repo | HARD Dependents | Total Dependents | Tier |
|---|---|---|---|
| `rhdh` | 9 | 10 | Tier 0 — Foundation |
| `rhdh-plugin-export-overlays` | 5 | 7 | Tier 1 — Core |
| `rhdh-chart` | 4 | 7 | Tier 1 — Core |
| `rhdh-plugins` | 4 | 5 | Tier 1 — Core |
| `rhdh-operator` | 3 | 7 | Tier 1 — Core |
| `rhdh-cli` | 3 | 4 | Tier 1 — Core |
| `rhdh-local` | 2 | 3 | Tier 2 — Support |
| `rhdh-must-gather` | 2 | 2 | Tier 2 — Support |
| `rhdh-plugin-export-utils` | 1 | 1 | Tier 2 — Support |
| `plugin-catalog-index` image (produced by overlays upstream / `rhdh-plugin-catalog` downstream) | 4 | 4 | Tier 1 — Core |
| `rhdh-e2e-test-utils` | 0 | 1 | Tier 3 — Leaf |
| `rhdh-adr` | 0 | 0 | Tier 3 — Leaf |
| `rhidp/Red Hat Developer Hub` (midstream) | 0 | 0 | Tier 3 — Aggregator |

**Circular dependencies identified** (bidirectional coupling requiring coordinated changes):

| Pair | Risk | Detail |
|---|---|---|
| `rhdh-plugin-export-overlays` <-> `rhdh-plugin-export-utils` | Critical | Overlays calls 10+ utils workflows at `@main` (no version pinning); utils workflows operate on the overlays repo as their target |
| `rhdh` <-> `rhdh-plugins` | High | `rhdh` depends on 16+ plugin npm packages; `rhdh-plugins` hardcodes `rhdh` registry constants and filesystem paths |
| `rhdh-plugins` <-> `rhdh-plugin-export-overlays` | Medium | CI-level circular via codecov sync and CODEOWNERS references |

**Floating/unpinned references** (changes propagate without version control):

| Reference | Used By | Risk |
|---|---|---|
| `rhdh-plugin-export-utils/...@main` (10+ workflow calls) | `rhdh-plugin-export-overlays` CI | Critical — no SHA, no version tag |
| `quay.io/rhdh-community/rhdh:next` | `rhdh-operator`, `rhdh-chart` nightly | High — floating image tag |
| `quay.io/rhdh/plugin-catalog-index:next` | `rhdh-operator` default deployment | High — floating image tag on catalog index |
| `raw.githubusercontent.com/.../refs/heads/main/...` | `rhdh` CI, `rhdh-e2e-test-utils`, `rhdh-plugins` | High — runtime raw GitHub fetch |
| `quay.io/rhdh-community/rhdh-must-gather:latest` | `rhdh-chart` | Medium — floating image tag |

### 2. Churn Analysis (baseline, to be refreshed quarterly)

**Repository activity ranking** (last 12 months, as of June 2025):

| Rank | Repository | 12-Month Commits | 6-Month Trend | HARD Dependents | Status |
|---|---|---|---|---|---|
| 1 | `rhidp/Red Hat Developer Hub` (midstream) | 3,306 | -12% | 0 (aggregator) | Hyperactive (bot-driven) |
| 2 | `rhdh-plugins` | 1,971 | +50% | 4 | Hyperactive (accelerating) |
| 3 | `rhdh-plugin-export-overlays` | 1,521 | +100% | 5 | Hyperactive (doubled) |
| 4 | `rhdh` | 1,006 | +3% | 9 | Active (stable) |
| 5 | `rhdh-operator` | 523 | -4% | 3 | Active (stable) |
| 6 | `rhdh-must-gather` | 465 | +87% | 2 | Active (accelerating) |
| 7 | `rhdh-chart` | 222 | +244% | 4 | Active (accelerating sharply) |
| 8 | `rhdh-plugin-export-utils` | 137 | -10% | 1 | Low activity |
| 9 | `rhdh-local` | 128 | +77% | 2 | Low activity (accelerating) |
| 10 | `rhdh-cli` | 119 | -50% | 3 | Declining |
| 11 | `rhdh-e2e-test-utils` | 77 | -14% | 0 (1 SOFT) | Low activity |
| 12 | `rhdh-adr` | 31 | N/A | 0 | New (started April 2026) |

**File-level churn hotspots** (most-changed files in repos with high dependency fan-in):

| Repository | Hotspot Files | Commits (6 months) | Why It Matters |
|---|---|---|---|
| `rhdh` | `yarn.lock` | 81 | Dependency changes ripple to 9 dependents; lock file conflicts block builds |
| `rhdh` | `build/containerfiles/Containerfile` | 23 | Image build changes affect every downstream consumer of the RHDH image |
| `rhdh` | `e2e-tests/package.json` + `playwright.config.ts` | 34 + 22 | E2E infrastructure churn can mask real regressions |
| `rhdh-plugins` | `workspaces/lightspeed/plugins/*/package.json` | 53 | Highest-churn plugin; changes propagate through overlays, chart, operator, local |
| `rhdh-plugin-export-overlays` | `.github/workflows/pr-actions.yaml` | 26 | CI workflow changes affect all 67+ workspace overlay builds |
| `rhdh-operator` | `go.mod` / `go.sum` | 117 / 109 | Dependency churn in the operator propagates to downstream bundle CSV |
| `rhdh-operator` | `api/v1alpha6/backstage_types.go` | 397 lines churned | CRD schema changes propagate to chart, downstream, must-gather |
| `rhdh-must-gather` | `collection-scripts/common.sh` | 51 (3,453 lines) | Core collection logic; regressions degrade customer support diagnostics |
| `rhdh-chart` | `.github/workflows/bump-version.yaml` | 42 | Chart versioning automation; breakage blocks Helm deployments |

### 3. Risk Crosswalk (dependency fan-in x churn = fragility)

Cross-referencing the dependency map with the churn data identifies fragile components — those that are both highly depended-upon AND frequently changing. High churn means more opportunities for breakage; high fan-in means breakage propagates widely.

**Critical risk** (high fan-in + high churn — act this quarter):

| Component | Fan-In | Churn | Why It's Fragile |
|---|---|---|---|
| `rhdh-plugin-export-overlays` <-> `rhdh-plugin-export-utils` pipeline | 5 + 1 HARD dependents | 1,521 commits/yr (+100% velocity) | Bidirectional critical coupling with 10+ `@main` workflow calls and no version pinning. Doubled velocity means doubled opportunity for breakage. A bad push to either repo halts all plugin publishing. |
| `rhdh-cli` | 3 HARD dependents | 119 commits/yr (-50% declining) | A depended-upon component whose commit velocity is declining — indicating it may not be keeping pace with the needs of the 3 repos that depend on its `export-dynamic-plugin` command. Low activity on a critical-path component means bugs and compatibility issues accumulate. The command is now `rhdh-cli plugin export` (renamed from the older `@janus-idp/cli export-dynamic-plugin`). |
| `rhidp/Red Hat Developer Hub` (midstream) automation | Aggregates 7 upstream repos | 3,306 commits/yr (77% bot-driven) | Highest raw commit volume in the ecosystem, almost entirely automated. When automation breaks on a repo with this much throughput, the backlog accumulates fast and blocks product releases. |
| `cli-module-install-dynamic-plugins` (in `rhdh-plugins`) | Every RHDH pod depends on it | Part of rhdh-plugins (1,971 commits/yr, +50%) | Maximum blast radius — every RHDH pod startup runs this in an init container. Recently migrated from Python to TypeScript (1.10+), adding a cross-repo npm dependency where there was previously a self-contained script. Still in the early breakage window. |

**High risk** (high churn or high fan-in — act within 2 quarters):

| Component | Fan-In | Churn | Why It's Fragile |
|---|---|---|---|
| `rhdh-must-gather` | 2 HARD dependents | 465 commits/yr (+87% accelerating) | Support-critical tool with rapidly accelerating churn. Core collection script (`common.sh`) has 3,453 lines churned in 6 months — high change velocity on code that runs against live customer deployments. |
| `rhdh-e2e-test-utils` | ~67 overlay workspaces depend on it (SOFT) | 77 commits/yr | Core utility `plugin-metadata.ts` has 1,618 lines of churn — the most-changed file relative to the repo's size. Changes here break E2E test infrastructure across all overlay workspaces. |
| `rhdh-operator` CRD schema | 3 HARD dependents + propagates to chart, downstream, must-gather | 523 commits/yr; `api/v1alpha6/backstage_types.go` has 397 lines churned | CRD types in active evolution. Every schema change must be absorbed by chart templates, downstream CSV manifests, and must-gather collection scripts — a ripple effect across 4 repos. |
| Lightspeed plugin (cross-cutting) | Spans 5+ repos | Highest-churn feature: 53+ commits in rhdh-plugins alone | Fastest-moving feature area across the ecosystem, touching `rhdh-plugins`, `rhdh-plugin-export-overlays`, `rhdh-chart`, `rhdh-operator` (flavour config), `rhdh-local`. No cross-repo integration gate means each repo merges Lightspeed changes independently with no joint validation. |

### 4. Monitoring with Existing Tools

The primary goal of this ADR is **awareness** — understanding which components are fragile and why, so the team can monitor them using the tools already in place. The dependency map and inner-component analysis above provide the context; the tools below provide the ongoing visibility.

**Existing monitoring tools mapped to fragility areas:**

| Tool | URL | What to Monitor |
|---|---|---|
| **AI Commits Scanner** | [ai-commits-scanner](https://ai-commits-scanner-fd01cc.pages.redhat.com/rhdh/index.html) | Track commit velocity trends across all 12 repos. Watch for churn acceleration in high-fan-in repos (`rhdh`, `rhdh-plugin-export-overlays`, `rhdh-operator`). Detect when a depended-upon repo's velocity declines (e.g., `rhdh-cli` at -50%) or when a fragile component's churn accelerates (e.g., `rhdh-must-gather` at +87%). |
| **Codecov** | [codecov/redhat-developer](https://app.codecov.io/gh/redhat-developer) | Monitor test coverage on the highest-blast-radius components identified in this ADR: `cli-module-install-dynamic-plugins` (init container), `rhdh-plugin-export-overlays` scripts (catalog index generation), `rhdh-must-gather` collection scripts (`common.sh`). Coverage drops in these areas are higher-risk than coverage drops elsewhere. |
| **ReportPortal** | Overlays dashboard | Track E2E test stability across the plugin export pipeline. The overlays repo processes 64 workspaces through shared CI — a flaky test in the shared infrastructure affects all workspaces. Use ReportPortal to distinguish between workspace-specific failures and shared-infrastructure regressions. |

**How to use these tools with the fragility data:**

- **Quarterly review**: Compare current AI Commits Scanner data against the churn baseline in Section 2. If a repo in the Critical risk tier (Section 3) has accelerated further, escalate in sprint planning.
- **PR review context**: When reviewing PRs that touch files identified as inner-component hotspots (Section 8) — e.g., `common.sh`, `generateCatalogIndex.py`, `deployment.go`, `_helpers.tpl` — check Codecov for coverage on those specific files and ReportPortal for recent test stability trends.
- **Incident correlation**: When a cross-repo breakage occurs, use the dependency map (Section 1) and the inner-component fragility analysis (Section 8) to trace the propagation path and identify which monitoring signal should have caught it earlier.

### 5. Known Structural Risks

The following structural risks were identified during the analysis. They cannot be addressed through monitoring alone — they are properties of how the repos are wired together.

- **Unpinned cross-repo workflow calls.** `rhdh-plugin-export-overlays` calls 10+ workflows in `rhdh-plugin-export-utils` at `@main` with no SHA or version pinning. A bad push to `main` in `rhdh-plugin-export-utils` immediately breaks all plugin publishing CI.

- **Raw GitHub downloads in CI.** At least 3 repos (`rhdh`, `rhdh-e2e-test-utils`, `rhdh-plugins`) fetch shell scripts at runtime from `raw.githubusercontent.com/.../refs/heads/main/...`. A file rename or path change silently breaks downstream CI with no version control signal.

- **Floating `next`/`latest` image tags in non-development contexts.** `quay.io/rhdh-community/rhdh:next` is used as the default in `rhdh-operator`'s deployment config; `quay.io/rhdh/plugin-catalog-index:next` is used as the default catalog index in the same config; `quay.io/rhdh-community/rhdh-must-gather:latest` is used in `rhdh-chart`. A bad push to any of these tags breaks all new deployments or diagnostic collection.

- **CRD schema ripple effect.** Every CRD schema change in `rhdh-operator` propagates to `rhdh-chart`, `rhidp/Red Hat Developer Hub` (midstream), and `rhdh-must-gather`. (See also [ADR-005: CRD Version Management](005-crd-version-management.md).)

- **Downstream catalog index visibility gap.** The downstream `rhdh-plugin-catalog` GitLab repo (`gitlab.cee.redhat.com/rhidp/rhdh-plugin-catalog`) produces the production `plugin-catalog-index` image consumed by all product deployments, but it sits outside the GitHub-based dependency graph analyzed here.

- **Archived dependency with no upstream fix path.** `@janus-idp/backstage-plugin-audit-log-node` is a runtime `peerDependency` in `rhdh-plugins` sourced from the archived `janus-idp/backstage-plugins` repo. Any vulnerability or incompatibility has no upstream fix path.

### 6. The Dynamic Plugin Installer Migration (detailed context)

In RHDH 1.10, the dynamic plugin installer migrated from a self-contained Python script (`install-dynamic-plugins.py`, lived in the `rhdh` image) to a TypeScript/Node.js npm package (`@red-hat-developer-hub/cli-module-install-dynamic-plugins`, published from `rhdh-plugins` repo, workspace `workspaces/install-dynamic-plugins/`).

**Before (RHDH <= 1.9):**
```
dynamic-plugins.yaml
  -> install-dynamic-plugins.py (Python, self-contained in rhdh image)
    -> skopeo (OCI pull) / npm pack (NPM pull)
    -> /dynamic-plugins-root/ (on disk)
    -> app-config.dynamic-plugins.yaml (generated output)
```

The installer was internal to the `rhdh` image. No cross-repo dependency at this point in the chain.

**After (RHDH 1.10+):**
```
dynamic-plugins.yaml
  -> install-dynamic-plugins.sh (generated at container build time in Containerfile, not a static file)
    -> @red-hat-developer-hub/cli-module-install-dynamic-plugins
       (TypeScript, published from rhdh-plugins repo)
      -> skopeo (OCI pull) / npm (NPM pull)
      -> /dynamic-plugins-root/ (on disk)
      -> app-config.dynamic-plugins.yaml (generated output)
```

The wrapper script is a 2-line shim generated in `build/containerfiles/Containerfile` (lines 278-296) that runs `exec cli-module-install-dynamic-plugins install "$@"`. The installer is now an npm package from a different repository, adding a new cross-repo HARD dependency at the most critical runtime junction: init container startup.

**The runtime contract is unchanged** — input YAML schema, output file layout, hash-based change detection, lock file behavior, `{{inherit}}` semantics, OCI path auto-detection, registry fallback, and integrity algorithms are all preserved. The package provides two invocation paths (direct `bin/install-dynamic-plugins` and backstage-cli discovery via `createCliModule`), both running the same `installer.ts` pipeline.

**What improved:**
- Eliminated Python runtime dependency from the container image
- Added parallelized OCI downloads with cgroup-aware worker scaling
- Added streaming tar extraction (lower memory footprint: 20-80 MB peak RSS)
- Added structured security checks (path traversal, zip bomb, symlink, device file, SRI integrity verification)
- Unified on the Node.js runtime already present for the Backstage backend

**What the migration introduced as risk:**
- A new cross-repo npm dependency at the highest-blast-radius point in the system (every pod startup)
- The package is still in the early breakage window where edge cases from the Python-to-TypeScript rewrite may surface
- Runtime dependencies on `skopeo` and `npm` on `PATH` must be present in the container image (previously only Python was required)
- The `getWorkers()` concurrency function uses `availableParallelism()` to respect cgroup CPU limits — a new behavior not present in the sequential Python script, which needs validation on OpenShift pods with fractional CPU limits

**Specific mitigations for this component** are included in the P0 actions above (item 4: integration tests in container environment).

### 7. Complete Plugin Lifecycle Chain

For reference, the full chain from plugin source code to running in a pod is now:

```
1. rhdh-plugins               Source code (TypeScript plugins)
       |
2. rhdh-cli                   `plugin export` command (builds dist-dynamic/) + `plugin package` (wraps into OCI image)
       |
3. rhdh-plugin-export-utils   CI actions for packaging
       |
4. rhdh-plugin-export-overlays Per-plugin config, publishes individual plugin OCI images
       |
5. Catalog index generation   4-step pipeline orchestrated by update-index.sh:
   (a) bootstrapPluginBuilds.py → (b) generatePluginBuildInfo.py →
   (c) generateDynamicPluginsDefaultYaml.sh → (d) generateCatalogIndex.py
   (upstream: rhdh-plugin-export-overlays; downstream: rhdh-plugin-catalog on gitlab.cee.redhat.com)
       |
6. rhdh-chart / rhdh-operator References RHDH image + catalog index image in deployment config
       |
7. cli-module-install-dynamic-plugins  Init container reads catalog index, downloads plugins
   (in rhdh-plugins; supports CATALOG_INDEX_IMAGE + EXTRA_CATALOG_INDEX_IMAGES for merging multiple indexes)
       |
8. rhdh backend               Loads plugins via @backstage/backend-dynamic-feature-service scanning
                              /dynamic-plugins-root/ + receives --config app-config.dynamic-plugins.yaml
```

Eight serial links. Each has different ownership and different release cadences. A break at any link stops dynamic plugin delivery to end users.

### 8. The Plugin Catalog Index (link 5 in detail)

The **plugin catalog index** is a critical intermediate component that sits between individual plugin OCI images (published in step 4) and the deployment configuration that references them (step 6). It aggregates metadata about all available plugins into a single OCI image (`plugin-catalog-index`) that the init container consumes at pod startup.

**What the catalog index image contains:**
- `dynamic-plugins.default.yaml` — the default plugin configuration (which plugins are enabled, their settings)
- `catalog-entities/extensions/` — Package CRD entities for the Extensions UI (contains `plugins/`, `packages/`, and `collections/` subdirectories)
- `index.json` — a summary of all plugins with resolved OCI references and metadata

**Two parallel implementations exist:**

| | Upstream (community) | Downstream (product) |
|---|---|---|
| **Source** | `rhdh-plugin-export-overlays/scripts/update-index.sh` orchestrating a 4-step pipeline: `bootstrapPluginBuilds.py` → `generatePluginBuildInfo.py` → `generateDynamicPluginsDefaultYaml.sh` → `generateCatalogIndex.py` | `gitlab.cee.redhat.com/rhidp/rhdh-plugin-catalog` (RH VPN required) |
| **CI trigger** | GitHub Actions workflow `generate-catalog-index.yaml`, triggered on push to `main`/`release-*` | GitLab CI in the downstream repo |
| **Output images** | `quay.io/rhdh-community/plugin-catalog-index` (supported tier), `ghcr.io/redhat-developer/rhdh-plugin-export-overlays/plugin-catalog-index` (community tier) | `registry.access.redhat.com/rhdh/plugin-catalog-index` (production), `quay.io/rhdh/plugin-catalog-index` (pre-prod) |
| **Input** | `workspaces/*/metadata/*.yaml` (Package entities), `default.packages.yaml`, `rhdh-supported-packages.txt`, `rhdh-community-packages.txt` | Overlay repo metadata (synced from upstream) |

**How it is consumed:**
- The `rhdh-operator` sets `CATALOG_INDEX_IMAGE=quay.io/rhdh/plugin-catalog-index:next` as an environment variable on the init container (see `config/profile/rhdh/default-config/deployment.yaml:72-73`)
- The `rhdh-chart` configures the catalog index via `global.catalogIndex.image` in `values.yaml` with a versioned tag (`rhdh/plugin-catalog-index:1.10`), not a floating tag (see `charts/backstage/values.yaml:31-36`)
- The `rhdh-local` docker-compose sets `CATALOG_INDEX_IMAGE=quay.io/rhdh/plugin-catalog-index:1.10` in `default.env`
- At pod startup, `cli-module-install-dynamic-plugins` detects the `CATALOG_INDEX_IMAGE` environment variable (and optionally `EXTRA_CATALOG_INDEX_IMAGES` to merge multiple indexes), uses `skopeo` to pull and extract the image, reads `dynamic-plugins.default.yaml` to determine which plugins to install by default, and extracts `catalog-entities/extensions/` for the Extensions UI

**Why this link is critical:**
- Without a valid catalog index image, the init container falls back to whatever `dynamic-plugins.yaml` is provided by the user — losing all default plugin configuration and Extensions UI metadata
- The upstream `generateCatalogIndex.py` script performs OCI registry queries to verify that each plugin image actually exists before including it in the index; a registry outage or credential issue during generation produces a degraded index
- The downstream `rhdh-plugin-catalog` repo on GitLab is an additional repository not visible in the GitHub dependency graph, creating a blind spot in cross-repo coupling analysis
- The `plugin-catalog-index:next` floating tag in the operator default config means a bad catalog index build can propagate immediately to all new operator-managed deployments

**Dependencies of the catalog index generation pipeline:**

| From | To | Type | Detail |
|---|---|---|---|
| `rhdh-plugin-export-overlays` (catalog index workflow) | `rhdh-plugin-export-overlays` (workspace metadata) | Internal | Reads `workspaces/*/metadata/*.yaml` for Package CRD entities and OCI references |
| `rhdh-plugin-export-overlays` (catalog index workflow) | `rhdh` | HARD | Fetches `package.json` from `raw.githubusercontent.com/redhat-developer/rhdh` to determine RHDH version for tagging |
| `rhdh-plugin-export-overlays` (catalog index workflow) | Plugin OCI registries (GHCR, Quay) | HARD | Queries registries to verify plugin images exist and resolve digest metadata |
| `rhdh-operator` | `plugin-catalog-index` image | HARD | Default deployment config sets `CATALOG_INDEX_IMAGE` env var (floating `next` tag) |
| `rhdh-chart` | `plugin-catalog-index` image | HARD | `values.yaml` references `rhdh/plugin-catalog-index:1.10` |
| `rhdh-local` | `plugin-catalog-index` image | HARD | `default.env` pins `CATALOG_INDEX_IMAGE` |
| `cli-module-install-dynamic-plugins` | `plugin-catalog-index` image | HARD | Reads at init container startup to determine default plugins and extract `catalog-entities/extensions/` for the Extensions UI |
| `rhidp/Red Hat Developer Hub` (midstream) | `rhdh-plugin-catalog` (GitLab) | HARD | Downstream build depends on the downstream catalog index for product releases |

**Risk assessment:**
- The catalog index is consumed by 4 repos (operator, chart, local, downstream) and is on the critical runtime path (init container)
- The upstream generation is automated via GitHub Actions in `rhdh-plugin-export-overlays` — it inherits that repo's churn characteristics (1,521 commits/year, +100% velocity)
- The downstream `rhdh-plugin-catalog` on GitLab is outside the GitHub-based analysis performed in this ADR and should be assessed separately
- The `plugin-catalog-index:next` floating tag in the operator default config is flagged as a high-risk unpinned reference (see the floating references table above)

### 9. Inner Component Fragility (what's breaking inside the most critical repos)

The repo-level analysis above identifies _which_ repos are fragile. This section goes one level deeper to show _what inside each repo_ concentrates the risk — the specific scripts, modules, config files, and CI workflows where churn is highest and blast radius is greatest.

#### 9.1 `rhdh-plugin-export-overlays` — 1,521 commits/yr, +100% velocity

The highest-velocity repo in the ecosystem. It contains 64 plugin workspaces, 21 scripts, and 22 CI workflows — all tightly coupled.

**Inner components:**

| Component | Size | Churn | Why It's Fragile |
|---|---|---|---|
| **`workspaces/`** (64 dirs) | 850 files total | 1,150 commits (69% of all repo churn) | Each workspace has `source.json`, `plugins-list.yaml`, and `metadata/*.yaml`. 33% of all repo commits are automated daily `source.json` ref updates via `update-plugins-repo-refs.yaml`. A failure in this single workflow blocks the entire daily update pipeline for all 64 workspaces. |
| **`scripts/generateCatalogIndex.py`** | 1,042 lines | Part of the catalog index critical path | Reads all 179 metadata YAML files across 64 workspaces, queries OCI registries (GHCR, Quay) to verify plugin images exist, and produces the catalog index. A parsing error in any one metadata file can break the entire index. Depends on `plugin_utils.py` (749 lines) for shared logic. |
| **`scripts/generateDynamicPluginsDefaultYaml.sh`** | 380 lines | Produces the DPDY consumed by downstream RHDH builds | Reads `default.packages.yaml` (121 lines, manually maintained PM-approved plugin list) to determine which plugins are enabled by default. A mistake in `default.packages.yaml` silently changes which plugins ship enabled in the product. |
| **`export-workspaces-as-dynamic.yaml`** (CI) | Reusable workflow | Called by both publish workflows | Processes all 64 workspaces in a single run. 11 workspaces have patches, 10 have overlays — each a potential failure point. A bug in this shared workflow blocks all plugin OCI image publishing. |
| **`default.packages.yaml`** | 121 lines | Low churn but maximum blast radius | Single file that determines which of the 64 workspaces' plugins are GA, Tech Preview, or community. Feeds DPDY generation and catalog index tier classification. Must stay in sync with `rhdh-supported-packages.txt` (100 lines) and `rhdh-community-packages.txt` (56 lines) — a 3-file manual coordination task with no automated cross-file consistency validation. |

**Structural fragility pattern**: One-to-many amplification. A single change to any shared script, workflow, or config file fans out across 64 workspaces. The `backstage` workspace alone covers 37 core plugins with 383 file-level changes — the highest churn of any workspace.

#### 9.2 `rhdh` — 3,306 commits/yr, 9 HARD dependents, 77% bot-driven

The main RHDH container image repo and the most-depended-upon component in the ecosystem.

**Inner components:**

| Component | Size | Churn | Why It's Fragile |
|---|---|---|---|
| **`dynamic-plugins/wrappers/`** | 41 plugin wrappers, own `yarn.lock` (35,033 lines) | 445 commits (highest-churn directory) | Each wrapper's `package.json` pins an upstream plugin version. ArgoCD, Kubernetes, and TechDocs wrappers each have 70+ touches. These version bumps ripple into the container build. The wrappers have a separate `yarn.lock` from the root, creating two independent dependency resolution trees in a single repo. |
| **`build/containerfiles/Containerfile`** | 344 lines | 23 commits (6 months) | Multi-stage UBI9 build that installs ~150 RPMs, builds the Backstage app, exports dynamic plugins, and creates a TechDocs Python venv. Consumed by Konflux build pipelines, operator, and midstream builds. A breakage here blocks all RHDH image production. |
| **`yarn.lock`** (root) | 37,571 lines | 681 commits (24% of all repo churn) | Renovate drives the majority of these changes. Lock file conflicts are the most frequent build-blocking issue. Combined with `dynamic-plugins/yarn.lock` (35,033 lines), the repo manages 72,604 lines of lock files — two independent dependency trees that can conflict with each other. |
| **`e2e-tests/`** | Playwright suite, 12+ test configurations | 659 commits (23% of repo churn) | Tests run across OCP, AKS, EKS, and GKE with Helm and Operator variants. The test infrastructure itself is a significant source of churn — `e2e-tests/package.json` has 189 touches. Test flakiness masks real regressions. |
| **`.ci/`** (OpenShift CI scripts) | `utils.sh` (102 touches), `openshift-ci-tests.sh` (76 touches) | 56 commits | The CI orchestration layer that drives Prow-based testing. `env_variables.sh` loads Vault secrets. These scripts are the glue between GitHub workflows and OpenShift CI infrastructure — not well-covered by the repo's own tests. |
| **`app-config.dynamic-plugins.yaml`** | 637 lines | Part of the runtime contract | Default dynamic plugin enable/disable configuration shipped in the container image. Changes here affect which plugins are available out-of-the-box for every RHDH deployment. |

**Structural fragility pattern**: Bot-driven velocity masking real risk. 77% of commits are automated (Renovate, base image updates, RPM lock syncs), which means the repo's raw commit count overstates human-driven change. But the automation itself is a risk surface — 25 GitHub workflows, auto-approve for Renovate PRs, and nightly image builds mean a misconfigured bot can ship a broken image to the `:next` tag before anyone reviews it.

#### 9.3 `rhdh-plugins` — 1,971 commits/yr, +50% velocity

A 23-workspace Yarn 4 monorepo containing both the highest-blast-radius runtime component (`install-dynamic-plugins`) and the highest-churn feature (`lightspeed`/`orchestrator`).

**Inner components:**

| Component | Size | Churn | Why It's Fragile |
|---|---|---|---|
| **`workspaces/orchestrator/`** | Largest workspace | 494 commits (highest in repo) | The most active workspace by commit count. Orchestrator spans plugins, backend, common types, and an editor UI. Changes here propagate to overlays, chart (SonataFlow templates), and operator (flavour config). |
| **`workspaces/lightspeed/`** | 47,202 lines of TS/TSX across 3 plugins | 340 commits (2nd highest) | `LightSpeedChat.tsx` is 2,198 lines — a single-file complexity hotspot. Backend `router.ts` is 739 lines handling chat, conversations, and MCP proxy. The notebooks subsystem (vector stores, document parsing, sessions) adds a second major feature surface. Currently being rebranded to "Intelligent Assistant" — a naming change that touches every file. |
| **`workspaces/install-dynamic-plugins/`** | 5,594 lines across 35 TypeScript files | Only 3 commits (recently migrated) | The init container installer. Core logic chain: `installer.ts` (656 lines) → `merger.ts` (572 lines) → `catalog-index.ts` (328 lines). Despite low commit count, this is the highest-blast-radius code in the entire ecosystem — a regression here means zero plugins load on any RHDH pod. Low churn is currently a positive (stable after migration), but any change requires extreme caution. |
| **`workspaces/bulk-import/`** | — | 239 commits (3rd highest) | Active workspace with significant ongoing development. |
| **Shared CI infrastructure** | 21 workflow files | Shared across all 23 workspaces | `ci.yml` runs on every PR and builds/tests/lints affected workspaces. The release pipeline uses changesets for versioning. A CI regression blocks all 23 workspaces simultaneously. |

**Structural fragility pattern**: Asymmetric blast radius. The 23 workspaces have wildly different risk profiles — `orchestrator` and `lightspeed` together account for 834 commits (42% of the top workspace churn) but `install-dynamic-plugins` with only 3 commits has more blast radius than the rest combined. Standard churn-based prioritization would miss it.

#### 9.4 `rhdh-operator` — 523 commits/yr, 3 HARD dependents

A Go-based Kubernetes operator with a CRD in active evolution.

**Inner components:**

| Component | Size | Churn | Why It's Fragile |
|---|---|---|---|
| **`.github/workflows/`** | 17 workflows | 322 commits (62% of all repo churn since June 2024) | By far the highest-churn directory. `pr.yaml` alone has 143 touches. CI infrastructure changes at this rate create an unstable foundation for validating the operator itself. |
| **`config/profile/rhdh/`** | 14+ files including flavour configs (lightspeed, orchestrator), plugin-deps, patches | 93 commits | The RHDH deployment profile defines `CATALOG_INDEX_IMAGE`, `RELATED_IMAGE_backstage`, and plugin dependency CRDs. Changes here directly affect what gets deployed by the operator. Two profiles exist (upstream `backstage.io` and downstream `rhdh`) that must stay conceptually aligned. |
| **`pkg/model/deployment.go`** | 518 lines | 27 commits (most-changed Go source file) | Constructs the Backstage Deployment object — the core runtime artifact. Sets `RELATED_IMAGE_backstage` and env var injection. A bug here produces invalid Deployments for every operator-managed RHDH instance. |
| **`pkg/model/dynamic-plugins.go`** | 322 lines | Part of model layer (58 commits total) | Handles init container configuration and dynamic plugin volume mounts. This is where the operator wires `cli-module-install-dynamic-plugins` into the pod spec. |
| **`api/v1alpha5/backstage_types.go`** | 397 lines (growing ~25 lines per version) | 39 commits in `api/` | The CRD type definition. Each version adds ~25 lines. `api/current-types.go` (60 lines) provides version indirection so application code imports from `api/` rather than a versioned package. The CRD YAML manifest is 2,169 lines. |
| **`bundle/rhdh/manifests/`** | CSV at 453 lines | 76 commits (highest-churn non-dependency file) | The OLM ClusterServiceVersion — consumed by downstream builds and OLM catalogs. Every CRD change, RBAC change, or image reference update requires a CSV regeneration. |
| **`dist/rhdh/install.yaml`** | 4,096 lines | 51 commits | All-in-one install manifest. Must be regenerated whenever CRD, RBAC, or deployment config changes — a derived artifact that can fall out of sync with its sources. |

**Structural fragility pattern**: CRD ripple effect. A type change in `api/v1alpha5/backstage_types.go` triggers regeneration of `zz_generated.deepcopy.go`, the CRD YAML (2,169 lines), the bundle CSV (453 lines), and `dist/install.yaml` (4,096 lines) — all within this repo. Then it propagates externally to `rhdh-chart` (templates must handle new fields), `rhidp/Red Hat Developer Hub` (midstream) (CSV must be synced), and `rhdh-must-gather` (collection scripts must gather new CRD fields). One type change → 7+ file regenerations internally → 3+ repos externally.

#### 9.5 `rhdh-must-gather` — 465 commits/yr, +87% accelerating

A support-critical diagnostic tool with the fastest-accelerating churn in the ecosystem.

**Inner components:**

| Component | Size | Churn | Why It's Fragile |
|---|---|---|---|
| **`collection-scripts/common.sh`** | 1,998 lines | 73 touches (tied for most-changed file in repo) | Shared library used by all 7 collectors. Contains `safe_exec()`, namespace filtering, workload/pod/log collection, and heap dump logic. Every collector depends on this file — a regression here breaks all diagnostic collection. |
| **`collection-scripts/must_gather`** | 344 lines | 34 touches | Main orchestrator that parses flags and runs all collectors sequentially. Controls the execution order: platform → helm → operator → orchestrator → route → ingress → namespace-inspect, then sanitize on exit. |
| **`collection-scripts/gather_helm`** | 452 lines | 23 touches | Collects Helm-deployed RHDH instances. Detects both native Helm releases and standalone `helm template` deployments via labels. |
| **`collection-scripts/gather_operator`** | 293 lines | — | Collects OLM resources (CSVs, Subscriptions, InstallPlans), CRDs (`backstages.rhdh.redhat.com`), Backstage CRs. Must track CRD schema changes from `rhdh-operator`. |
| **`collection-scripts/sanitize`** | 193 lines | — | Post-collection redaction of secrets, tokens, SSH keys, passwords. Produces `sanitization-report.txt`. A false negative leaks customer credentials; a false positive removes diagnostic data. |
| **`Containerfile`** | Multi-stage UBI9 build | 53 touches (3rd most-changed file) | Stage 1 compiles `websocat` from vendored Rust source for heap dumps via Chrome DevTools WebSocket protocol. Stage 2 installs runtime deps (jq, python3/yq, rsync). Hermetic build via Konflux. |
| **`tests/`** | BATS unit tests + E2E suite | E2E runner at 891 lines, 38 touches | BATS unit tests cover all collectors. E2E tests use Kind clusters. `run-e2e-tests.sh` (891 lines) validates operator, helm, heap-dump, and common collection scenarios. This is one of the better-tested repos — but the 1,998-line `common.sh` changes faster than its tests. |

**Structural fragility pattern**: Monolithic shared library. All 7 collectors import `common.sh` (1,998 lines). It's the most-touched file in the repo (73 changes) and the largest single script. The +87% acceleration means it's changing faster each quarter. Unlike the other repos where churn is spread across many files, here 1 file concentrates 15% of all repo changes and is a prerequisite for every collector.

#### 9.6 `rhdh-chart` — 319 commits/yr, 2 HARD dependents

The Helm chart that translates operator and user configuration into Kubernetes manifests.

**Inner components:**

| Component | Size | Churn | Why It's Fragile |
|---|---|---|---|
| **`charts/backstage/values.yaml`** | 555 lines | 53 touches | The primary configuration surface. Major sections: `global` (185 lines — catalog index image, cluster router base, TLS settings), `upstream` (267 lines — Backstage chart overrides), `route`, `orchestrator`. Every new operator feature or plugin integration requires a values.yaml change. |
| **`charts/backstage/values.schema.json`** | 8,404 lines | 54 touches | JSON Schema validation for values.yaml. At 8,404 lines, this is the largest single file in the repo. Every values.yaml addition requires a corresponding schema update — a manual sync that can drift. |
| **`charts/backstage/templates/_helpers.tpl`** | 359 lines | Most complex template file | Contains all Go template helpers (label generation, name resolution, init container injection, dynamic plugin ConfigMap assembly). A bug here silently produces invalid manifests. |
| **`vendor/backstage/charts/backstage/templates/backstage-deployment.yaml`** | 303 lines | Vendored upstream — synced via `sync-upstream-backstage.sh` | The actual Deployment manifest template. Vendored from upstream Backstage Helm chart (v2.8.0). Sync drift between vendor and upstream is a latent risk. |
| **`charts/backstage/Chart.yaml`** | — | 111 touches (most-changed file in repo) | Chart version bumped on nearly every change. Declares dependency on `bitnami/common v2.40.0` and vendored `backstage v2.8.0`. |
| **Orchestrator charts** (3 sub-charts) | `orchestrator-infra`, `orchestrator-software-templates`, `orchestrator-software-templates-infra` | — | Manage Tekton pipelines (243+ lines of pipeline templates), GitOps operator setup, and Serverless Logic infrastructure. These are less frequently changed but complex — a Tekton pipeline template error silently produces broken CI/CD for orchestrator users. |

**Structural fragility pattern**: Schema-values sync tax. Every feature addition requires a coordinated change across `values.yaml` (555 lines), `values.schema.json` (8,404 lines), and one or more template files — three files that must stay in sync with no automated validation that the schema matches the templates' consumption of values. The chart also vendors an upstream Backstage chart that must be periodically synced via `sync-upstream-backstage.sh`, adding a latent drift risk.

## Alternatives Considered

### Alternative 1: Consolidate into a monorepo
- **Approach**: Merge all 12 repositories into a single monorepo to eliminate cross-repo coupling
- **Rejected because**: The repos span Go (operator), TypeScript (plugins, CLI), Python (downstream scripts), and Bash (must-gather). They have fundamentally different build systems, test frameworks, and release cadences. A monorepo would create a single CI bottleneck and force coordinated releases across components that intentionally evolve independently. The multi-repo structure is architecturally sound; the problem is invisible coupling, not the repo boundary itself.

### Alternative 2: Ad-hoc risk management (status quo)
- **Approach**: Continue addressing risks as they surface through incidents and firefighting
- **Rejected because**: This is reactive, not proactive. The churn and dependency data show that several components are on trajectories toward failure (declining velocity on depended-upon repos, accelerating churn on high-fan-in repos with no integration tests). Waiting for incidents to occur before acting means the first signal is a production break or a blocked product release. The dependency mapping exercise has already identified specific, actionable risks that are cheaper to mitigate now than to recover from later.

### Alternative 3: Automated dependency scanning tools only
- **Approach**: Rely on tools like Dependabot, Renovate, or SBOM generators to track dependencies
- **Rejected because**: These tools handle npm/Go module dependencies within a single repo but do not detect the cross-repo coupling that creates the highest risk in this ecosystem: CI workflow calls at `@main`, raw GitHub URL downloads, hardcoded registry constants, container image tag references, and filesystem path assumptions. The most dangerous edges in the dependency map are invisible to package-level scanners. Automated tools complement but cannot replace the architectural analysis done here.

## Consequences

### Positive
- Gives the team a shared, concrete understanding of which components are fragile and why, replacing intuition with data
- Enables targeted monitoring — the fragility analysis tells the team exactly which repos, files, and pipelines to watch in AI Commits Scanner, Codecov, and ReportPortal, rather than treating all 12 repos equally
- Makes invisible cross-repo coupling visible, so teams can make informed decisions about when a change in their repo might break a downstream consumer
- Identifies fragile components (high churn + high fan-in) before they become incidents, providing early warning through existing tools
- Establishes a churn and dependency baseline that can be refreshed quarterly using AI Commits Scanner data to track whether risk is increasing or decreasing

### Negative
- The dependency map and churn analysis require periodic refresh (recommended quarterly) to remain accurate; if not maintained, it becomes stale and misleading
- Awareness without action can create a false sense of security — knowing a component is fragile is only valuable if the team acts on the monitoring signals
- Addressing the structural risks (unpinned references, floating tags) adds maintenance overhead for version bumps

### Neutral
- The dependency map documents the current state — it does not prescribe a different architecture. Structural improvements (repo consolidation, chain shortening) are optional long-term actions, not requirements
- Churn data reflects component change velocity, not code quality. High churn indicates fragility risk, not poor engineering — some components change frequently because they are actively evolving
- This ADR establishes the practice and initial baseline; future refreshes should update the data tables but do not require new ADRs unless the mitigation strategy changes
