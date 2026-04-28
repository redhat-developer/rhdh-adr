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

1. **Operator config merging**:
   - Discover all DevHubPluginCatalog resources automatically (from ADR-002)
   - Load plugin configs from catalog ConfigMaps (mirrored versions)
   - Load flavour configs (from ADR-001 flavour system)
   - Load user configs from ConfigMap (if specified in Backstage CR)
   - Merge in order: catalogs → flavours → user overrides

2. **Short identifier resolution**:
   - Detect package format: `oci://`, 'npm://', "./" → full URL (used as-is)
   - "ref://" → short identifier (catalog lookup for OCI package URL)
   - Resolve short identifiers by searching configured catalogs (returns OCI URL from catalog)
   - Strict validation: fail on unknown identifiers (protects against typos)
   - No version overrides with short identifiers (use catalog version exactly)

3. **Dual ConfigMap generation**:
   - `backstage-dynamic-plugins-<CR name>`: Merged plugin config for init container
     - Includes resolved (see Short identifier resolution) full package URLs
     - Includes `catalogSource` field for traceability
   - `backstage-appconfig-plugins-<CR-name>`: Extracted `pluginConfig` for Backstage app-config
     - Only plugin configuration (no package/installation info)
     - Both ConfigMaps includes Enabled plugins only

4. **Early validation**:
   - Validate merged config during reconciliation
   - Report errors, warnings in Backstage CR status 
   - Fail reconciliation on validation errors (fail fast)

5. **Backward compatibility**:
   - Existing init container works without modification
   - When operator provides merged configs → init container only downloads packages (merge steps become no-ops)
   - Helm deployments continue working (no operator configs provided, init container performs full merge as before)

**Example workflow:**

```
Operator Reconciliation:
├─ 1. List all DevHubPluginCatalog resources (cluster-wide)
├─ 2. Load plugins from <catalog>-catalog ConfigMaps
├─ 3. Load flavour configs (if applicable)
├─ 4. Load user configs from spec.application.dynamicPluginsConfigMapName
├─ 5. Merge configs (catalogs → flavours → user)
├─ 6. Resolve short identifiers → full package URLs
├─ 7. Validate merged config
│    ├─ If invalid: Update CR status, fail reconciliation
│    └─ If valid: Continue
├─ 8. Generate backstage-dynamic-plugins-<CR name> ConfigMap
├─ 9. Generate backstage-appconfig-plugins-<CR-name> ConfigMap
├─ 10. Create/Update Deployment with ConfigMaps mounted
└─ 11. Update CR status with plugin count, catalog sources
```

**Short identifier example:**

```yaml
# User's dynamic-plugins.yaml
plugins:
  # Short identifier - resolved from catalogs
  - package: ref://backstage-plugin-techdocs
    disabled: false

  # Full URL - used as-is (exact match)
  - package: oci://internal.registry/custom-plugin:1.0.0!custom-plugin
    disabled: false
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
✅ **Enables significant simplification of package downloading script** Light logic, potentially no Python needed   

### Negative

❌ **Operator complexity**: Config merging logic moves from bash scripts to Go controller code
❌ **Larger reconciliation loop**: More work during reconciliation (fetch catalogs, merge configs)
❌ **Testing burden**: Need comprehensive unit tests for merging logic, edge cases
❌ **ConfigMap management**: 1 additional ConfigMaps per Backstage instance (app-config)

### Neutral

⚖️ **Catalog dependency**: Config processing depends on DevHubPluginCatalog availability (coupled to ADR-002)
⚖️ **Plugin name extraction**: Operator must parse package URLs to extract plugin names (format-specific logic)
⚖️ **Init container still needed**: Operator provides configs but init container still downloads packages (can be optimized later with lightweight replacement). Having this dependency until support more than just "oci://"

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
- Catalog search order: How to prioritize when same plugin exists in multiple catalogs? Do we allow it at all?
- Config refresh: Should operator re-merge on catalog ConfigMap updates? (Slightly important only for development)
