# ADR: CR-Inline Application Configuration

## Context

**Problem**: Users of the RHDH Operator cannot easily define custom application configuration without creating and managing separate ConfigMaps.

Currently, the operator requires all app-config customization to be externalized to ConfigMaps, which creates friction for users who want to:
- Define simple, single app-config fragments directly in the Backstage CR
- View and modify app-config inline with their instance definition
- Avoid the overhead of creating and maintaining ConfigMaps for small configuration changes

The flexibility of ConfigMaps is valuable, but the default UX experience is unnecessarily complex for common use cases. Users must:
1. Create a ConfigMap with their app-config
2. Reference it in the CR (via `spec.application.appConfig.configMaps`)
3. Re-deploy or update the ConfigMap to make changes
4. Switch between files to review configuration

This creates a gap between "simple configuration" (should be inline) and "complex configuration" (appropriate for ConfigMaps).

## Decision

Introduce **`spec.application.appConfig.raw`**: a field for defining application configuration as a YAML fragment directly in the Backstage CR spec.

**Implementation approach**:

- Add `raw` field to `spec.application.appConfig` accepting a YAML string with app-config content
- `raw` inline config is merged **after** ConfigMaps by default, establishing a predictable merge order
- ConfigMaps can optionally specify `injectionOrder: post-spec` to be merged **after** the `raw` config
- Without `injectionOrder: post-spec`, ConfigMaps are merged **before** `raw` config, in their definition order

**Merge order**:
```
1. ConfigMaps (without injectionOrder: post-spec) in definition order
2. spec.application.appConfig.raw
3. ConfigMaps (with injectionOrder: post-spec) in definition order
```

**Example**:
```yaml
spec:
  application:
    appConfig:
      configMaps:
        - name: pre-config-1
        - name: post-config-1
          injectionOrder: post-spec
        - name: pre-config-2
      raw: |
        backend:
          database:
            client: 'pg'
```

Merge order: `pre-config-1` → `pre-config-2` → `raw` → `post-config-1`

## Alternatives Considered

### Alternative 1: Only inline config, remove ConfigMap support
- **Approach**: Replace ConfigMap mechanism entirely with CR-embedded config
- **Rejected because**: ConfigMaps are essential for large configs, secret management integration, and multi-instance sharing. Removing them would break existing workflows and force large configurations into CRs.

### Alternative 2: Simpler model - inline config always wins (no post-spec)
- **Approach**: `raw` config is always merged last, no option for post-spec ConfigMaps
- **Rejected because**: Some use cases need to override inline spec config (e.g., templated operators, multi-tenancy overlays). Post-spec merging provides necessary flexibility while remaining understandable.

## Consequences

### Positive
✅ Simplifies UX for users defining custom app-config (no ConfigMap creation needed for simple cases)
✅ Configuration visible inline with CR definition (easier to review, version control, audit)
✅ Backward compatible - existing ConfigMap mechanism unchanged, no breaking changes
✅ Flexible - supports primary pattern (spec overrides defaults) while allowing post-spec overrides when needed
✅ Reduces operator memory footprint - fewer ConfigMaps to watch means smaller informer cache

### Negative
❌ Increases CR size if users embed large configurations (ConfigMaps remain better choice for large configs)
❌ Two-level merge semantics (pre-spec, post-spec) adds conceptual complexity vs. simple linear ordering

### Neutral
⚖️ ConfigMap `injectionOrder` field introduces new CR schema extension - need clear documentation for discoverability
