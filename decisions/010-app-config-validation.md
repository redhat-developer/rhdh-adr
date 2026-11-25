# ADR-010: Operator App-Config Validation

## Context

**Problem**: App-config errors are only discovered at Backstage runtime, after deployment, when plugins fail to load or behave incorrectly.

**Current state:**
- Backstage validates configs at startup, but errors only appear in pod logs
- No validation occurs during CR reconciliation — operator blindly passes config to Backstage
- Configuration errors require pod restart to diagnose
- ADR-003 introduced "early validation" concept but without specific validation mechanisms

**Types of errors only discovered at runtime:**
1. **Schema violations**: Wrong types, missing required fields, invalid values
2. **Missing references**: Env vars that don't exist, files that aren't mounted

**Two categories of plugins require validation:**

1. **Core plugins** (hardcoded/non-dynamic): Plugins built into RHDH image
   - Discovered from RHDH's `packages/backend/package.json` and `packages/app/package.json` dependencies

2. **Dynamic plugins**: Plugins loaded at runtime from catalog
   - Discovered from catalog `index.json`

Both configure via **app-config**. Schemas are fetched from respective plugin source repositories.

**Who is impacted:**
- **Operators/SREs**: Invalid configs cause runtime failures, not reconciliation failures
- **Users**: No feedback on config errors until pod starts and plugin fails
- **Debugging**: Must read Backstage pod logs to understand issues

**Constraints:**
- Schemas defined in upstream plugin source repos, not in RHDH
- TypeScript schemas require conversion to JSON Schema
- Not all plugins have schemas — schema validation should be best-effort
- Schema validation only for plugins in a catalog (schemas extracted at catalog build time)
- Must not block deployment for plugins without schemas

## Decision

Implement two complementary validation mechanisms during Backstage CR reconciliation:

1. **Existence validation**: Verify that referenced env vars and files exist
2. **Schema validation**: Validate app-config against plugin JSON schemas

### 1. Existence Validation

Verify that config references resolve to actual data:

| Pattern | Validation |
|---------|------------|
| `${VAR}` | Env var exists (in ConfigMap, Pod env, etc.) |
| `$env: VAR` | Env var exists |
| `$file: path` | File/mount exists |
| `$include: path` | File exists |

**Behavior:**
- Non-secret references: fail if not found
- Secret references: warn only (may not have access)
- Report missing references in CR status

### 2. Schema Validation

Generate JSON Schema files during plugin catalog creation for both core and dynamic plugins.

**Schema extraction during catalog build** (in `rhdh-plugin-export-overlays`):

**For core plugins:**
- Core plugin schemas are included only in the [Default Catalog](https://github.com/redhat-developer/rhdh-adr/blob/main/decisions/002-devhub-plugin-catalog-crd.md) only
- Fetch `packages/backend/package.json` and `packages/app/package.json` from RHDH repo
- Extract plugin dependencies
- For each plugin, resolve source repository and fetch `configSchema`
- Convert TypeScript schemas to JSON Schema using `ts-json-schema-generator`

**For dynamic plugins:**
- For each plugin in catalog `index.json`, extract repository info from `io.backstage.dynamic-packages`
- Fetch `configSchema` from plugin source repo
- Convert TypeScript schemas to JSON Schema

**Catalog index image contents** (extended):
```
catalog-index/
├── index.json
├── dynamic-plugins.default.yaml
├── schemas/                                    # NEW
│   ├── manifest.json                           # Plugin inventory with schema status
│   ├── backstage-plugin-catalog-backend.json   # Core plugin
│   ├── backstage-plugin-kubernetes-backend.json
│   ├── backstage-community-plugin-acr.json     # Dynamic plugin
│   └── ...
└── ...
```

**Schema manifest format**:
```json
{
  "generatedAt": "2026-06-29T10:00:00Z",
  "corePlugins": ["backstage-plugin-catalog-backend", ...],
  "dynamicPlugins": ["backstage-community-plugin-acr", ...],
  "pluginsWithSchema": ["backstage-plugin-kubernetes-backend", ...],
  "pluginsWithoutSchema": ["backstage-plugin-home", ...],
  "stats": {
    "totalPlugins": 150,
    "corePlugins": 30,
    "dynamicPlugins": 120,
    "withSchema": 55,
    "withoutSchema": 95
  }
}
```

**Environment variable handling in schema validation:**

Config values may contain env var references (`${VAR}`, `$env: VAR`) substituted at Backstage runtime.

- **Stage 1**: Treat env var patterns as wildcard — accept any type, warn
- **Stage 2**: Resolve non-secret env vars and validate; for Secrets — warn only

**Schema validation behavior:**
- Schemas set `additionalProperties: true` (allow unknown fields for forward compatibility)
- Validation is non-blocking for plugins without schemas
- Strict JSON Schema draft-07 validation

### Operator Validation Flow

During reconciliation (extends ADR-003):
1. Load schemas from default-config (populated by DHPC from catalog)
2. **Existence validation**: Check all `${VAR}`, `$env:`, `$file:`, `$include:` references
3. **Schema validation**: Validate app-config against plugin schemas
4. Report validation errors/warnings in CR status
5. Fail reconciliation on errors (fail fast)

### CR Status Reporting

```yaml
status:
  conditions:
    - type: AppConfigValid
      status: "False"
      reason: ValidationFailed
      message: |
        Existence errors:
        - ${DATABASE_URL}: env var not found
        - $file: /etc/secrets/api-key: file not mounted

        Schema errors (backstage-plugin-kubernetes-backend):
        - $.kubernetes.clusterLocatorMethods[0].type: must be one of [config, gke, ...]
        - $.kubernetes.serviceLocatorMethod: required property missing
```

## Alternatives Considered

### Alternative 1: Schema extraction at operator runtime
- **Approach**: Operator fetches schemas from plugin source repos during reconciliation
- **Rejected because**: Requires network access during reconciliation; slow; unreliable; not air-gap compatible

### Alternative 2: Manual schema curation in operator
- **Approach**: Maintain curated JSON schemas in operator repo for known plugins
- **Rejected because**: High maintenance burden; schemas drift from upstream; doesn't scale

### Alternative 3: Schema extraction during plugin OCI build
- **Approach**: Include schema in each plugin's OCI image, extract at init container time
- **Rejected because**: Schemas scattered across images; harder to aggregate; doesn't cover core plugins

## Consequences

### Positive

✅ **Fail fast**: Invalid configs caught during reconciliation, not at runtime
✅ **Clear error messages**: Validation errors in CR status with specific field paths
✅ **Two-layer validation**: Catches both missing references and schema violations
✅ **CI/CD friendly**: Validate configs without deploying pods
✅ **Consistent with ADR-003**: Extends early validation pattern
✅ **Complete coverage**: Validates both core and dynamic plugins
✅ **Best-effort**: Plugins without schemas still get existence validation
✅ **Air-gap compatible**: Schemas bundled in catalog image, no runtime fetching

### Negative

❌ **Build complexity**: Catalog build must handle TypeScript-to-JSON-Schema conversion
❌ **Larger catalog image**: Schema files add ~2-5MB to catalog index image

### Neutral

⚖️ **Requires ts-json-schema-generator**: Build dependency for TypeScript schema conversion
⚖️ **Best-effort schema validation**: Silent pass for schema-less plugins
⚖️ **additionalProperties: true**: Allows unknown fields (forward compatible but less strict)
⚖️ **Env var limitation**: `${VAR}` values treated as wildcards in schema validation (Stage 1)

## Notes

**Related ADRs:**
- ADR-003 (Operator-Based Plugin Configuration Processing) — this extends early validation
- ADR-002 (DevHubPluginCatalog CRD) — catalog provides schema files

**Implementation phases:**
1. Add existence validation to operator reconciliation loop
2. Add schema extraction to catalog build scripts (`rhdh-plugin-export-overlays`)
3. Include schemas in catalog index OCI image
4. Add schema validation to operator reconciliation loop
5. Report validation results in CR status
6. (Future) Resolve non-secret env vars for full schema validation