# ADR: Operator-Based Plugin Configuration Processing

## Context

**Problem**: Plugin configuration processing happens in init containers at pod runtime, preventing early validation, clear error reporting, and config inspection before deployment.

**Current state:**
- Init container gets `dynamic-plugins.default.yaml` from catalog at pod startup
- Config merging happens late (after pod creation, in container)
- Validation errors only visible in init container logs (not in CR status)
- No way to inspect merged configuration before deployment
- Operator has no visibility into plugin configuration during reconciliation

**Who is impacted:**
- **Operators/SREs**: Config errors discovered after pod creation, not during reconciliation
- **Users**: Cannot preview merged configuration before deploying
- **Debugging**: Plugin config issues buried in init container logs, not in CR status
- **CI/CD pipelines**: Cannot validate plugin configs without creating pods

**Constraints:**
- Must maintain backward compatibility with existing Backstage CRs (including Helm-deployed instances)
- Must preserve existing config merge semantics (catalogs → flavours → user)
- Must support short identifier resolution 

## Decision

Move plugin configuration processing from init container to operator reconciliation loop, enabling early validation, config inspection, and fail-fast behavior during CR reconciliation.

**Implementation approach:**

1. **Catalog readiness check**:
   - DHPC creates `.catalogs-ready` marker entry in default-config when ready
   - Backstage controller checks for `.catalogs-ready` entry before proceeding
   - If not ready → requeue with status "waiting for catalog"
   - For local development (`make run`), static files with pre-created marker are used

2. **Operator config merging**:
   - Load plugin configs from default-config (already merged by DHPC)
   - Load flavour configs (from ADR-001 flavour system)
   - Load user configs from ConfigMap (if specified in Backstage CR)
   - Merge in order: default-config (catalogs) → flavours → user overrides
   - Reuses existing `MergePluginsData` function and `mergeDynamicPlugins` pattern

3. **Short identifier resolution**:
   - Detect package format:
     - `oci://...` → OCI registry URL (used as-is)
     - `@scope/name` or standard npm package name → NPM package (used as-is)
     - `./...` → local path (used as-is)
     - `ref://...` → short identifier (catalog lookup)
   - Resolve `ref://` by searching default-config (catalog data) for matching plugin
   - Strict validation: fail on unknown identifiers (protects against typos)
   - No version overrides with short identifiers (use catalog version exactly)

4. **Dual ConfigMap generation**:
   - `backstage-dynamic-plugins-<CR name>`: Merged plugin config for init container
     - Includes resolved full package URLs
     - Includes `catalogSource` field for traceability
     - Enabled plugins only
   - `backstage-appconfig-plugins-<CR-name>`: Extracted `pluginConfig` for Backstage app-config
     - Only plugin configuration (no package/installation info)
     - First in app-config chain (user's app-config overrides plugin defaults)
     - Enabled plugins only

5. **Early validation**:
   - Validate merged config during reconciliation
   - Report errors, warnings in Backstage CR status
   - Fail reconciliation on validation errors (fail fast)

6. **Backward compatibility**:
   - Feature gated by CR annotation `rhdh.redhat.com/plugin-processing: "operator"`
   - Default: absent or any other value → existing init container behavior
   - Enables gradual rollout and easy rollback; annotation to be removed once stable
   - Existing init container works without modification
   - When operator provides merged configs → init container only downloads packages
   - Helm deployments continue working (no operator, init container performs full merge)

**Example workflow:**

```
Operator Reconciliation:
├─ 1. Check for .catalogs-ready marker entry in default-config
│    └─ If not ready: Requeue with status "waiting for catalog"
├─ 2. Load plugin configs from default-config (populated by DHPC)
├─ 3. Load flavour configs (if applicable)
├─ 4. Load user configs from spec.application.dynamicPluginsConfigMapName
├─ 5. Merge configs (default-config → flavours → user)
├─ 6. Resolve ref:// short identifiers → full package URLs
├─ 7. Filter to enabled plugins only
├─ 8. Validate merged config
│    ├─ If invalid: Update CR status, fail reconciliation
│    └─ If valid: Continue
├─ 9. Generate backstage-dynamic-plugins-<CR name> ConfigMap
├─ 10. Generate backstage-appconfig-plugins-<CR-name> ConfigMap (first in app-config chain)
├─ 11. Create/Update Deployment with ConfigMaps mounted
└─ 12. Update CR status with plugin count, sources
```

**Short identifier example:**

```yaml
# User's dynamic-plugins.yaml
plugins:
  # Short identifier - resolved from catalogs
  - package: ref://backstage-plugin-techdocs
    enabled: true

  # Full URL - used as-is (exact match)
  - package: oci://internal.registry/custom-plugin:1.0.0!custom-plugin
    enabled: true
```

Operator resolves `backstage-plugin-techdocs` to full URL from catalog, validates it exists, and generates merged config.

## Consequences

### Positive

✅ **Early validation**: Config errors caught during reconciliation (fail fast with clear CR status)
✅ **Config visibility**: Inspect merged config via `kubectl get cm backstage-dynamic-plugins-<CR name> -o yaml`
✅ **Better debugging**: Validation errors in CR status, not init container logs
✅ **Catalog-based defaults**: Short identifiers enable portable configs (same config works everywhere)
✅ **Testable**: Unit test config merging logic without container builds
✅ **Operator awareness**: Operator knows about plugins (enables future features like dependency validation)
✅ **Enables lightweight init container**: Future optimization can replace heavy init container (currently containing Node.js/Python) with minimal package downloader for operator deployments
✅ **Enables significant simplification of package downloading script**: Light logic, potentially no Python needed
✅ **Seamless local development**: `make run` works with static files, no DHPC needed for testing   

### Negative

❌ **Operator complexity**: Config merging logic moves from bash scripts to Go controller code
❌ **Testing burden**: Need comprehensive unit tests for merging logic, edge cases
❌ **ConfigMap management**: 1 additional ConfigMap per Backstage instance (app-config)

### Neutral

⚖️ **Catalog readiness**: Backstage controller waits for `.catalogs-ready` marker entry (simple contract with DHPC)
⚖️ **Plugin name extraction**: Operator must parse package URLs to extract plugin names (format-specific logic)
⚖️ **Init container still needed**: Operator provides configs but init container still downloads packages (can be optimized later with lightweight replacement)
⚖️ **Reuses existing merge logic**: No changes to `MergePluginsData` or `mergeDynamicPlugins` - just different input source

## Notes

**Related ADRs:**
- ADR-002 (DevHubPluginCatalog CRD) provides catalog infrastructure this builds on
- ADR-001 (Flavour-Based Configuration) provides flavour configs used in merge order
- ADR-004 (Plugin Infrastructure Support) uses merged config for deployment patches

**Implementation details:**
- Plugin name extraction from OCI URLs:
  - `oci://host/path:tag!plugin-name` → "plugin-name" (explicit name after `!`)
  - `oci://host/path/plugin-name:tag` → "plugin-name" (last path segment)

**Open questions for implementation:**
- Config refresh: Should Backstage controller re-reconcile when default-config changes? (ConfigMap watch or periodic)
