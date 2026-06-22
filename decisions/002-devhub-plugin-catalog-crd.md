# ADR: DevHubPluginCatalog CRD for Plugin Catalog Management

## Context

**Problem**: Plugin catalog information is embedded in OCI artifacts and inaccessible before deployment, preventing air-gap workflows, early validation, and multi-catalog support.

**Current state:**
- `dynamic-plugins.default.yaml` stored in catalog OCI artifact (image)
- Catalog fetched by init container at pod runtime
- No visibility into plugin defaults before pod creation
- Single catalog limitation (primary RHDH catalog only)
- Air-gap users cannot discover required images before installation

**Who is impacted:**
- **Air-gap/disconnected users**: Cannot pre-mirror plugin images because catalog content is unknown until pod runtime
- **Operators/SREs**: Cannot validate plugin configurations early in reconciliation loop
- **Multi-catalog users**: Cannot combine dynamic-plugins.default.yaml files from primary catalog with custom or third-party plugin catalogs
- **Platform teams**: No cluster-wide catalog reuse across multiple Backstage instances

**Constraints:**
- Must support disconnected/air-gap environments
- Must enable catalog content inspection before deployment
- Must support multiple catalogs (primary RHDH + custom/third-party)

## Decision

Introduce **DevHubPluginCatalog** as a cluster-scoped Custom Resource Definition (CRD) to manage plugin catalogs as first-class Kubernetes resources, enabling catalog discovery, multi-catalog support, and air-gap workflows.

**Implementation approach:**

1. **Cluster-scoped CRD**:
   - `DevHubPluginCatalog` resources visible cluster-wide
   - DHPC controller reconciles catalog resources
   - One catalog resource can serve multiple Backstage instances

2. **Catalog lifecycle**:
   - Fetch catalog from OCI source (`spec.source.oci`)
   - Extract `dynamic-plugins.default.yaml` from catalog artifact
   - If `spec.mirror` specified, apply mirror configuration to URLs

3. **Primary RHDH catalog auto-creation**:
   - Default DevHubPluginCatalog resource included in operator installation
   - Created automatically when operator is installed

4. **Multi-catalog support**:
   - Users can create additional DevHubPluginCatalog resources
   - DHPC automatically discovers and merges all catalogs
   - Primary catalog MUST include `dynamic-plugins.default.yaml`
   - Extra catalogs MAY include `dynamic-plugins.default.yaml` (optional)

5. **Default-config integration**:
   - DHPC merges all catalogs and writes to the existing `default-dynamic-plugins` ConfigMap
   - Updates `dynamic-plugins.yaml` entry with resolved plugin data (replaces `includes:` reference)
   - Creates `.catalogs-ready` marker file in the ConfigMap when ready
   - Backstage controller checks for `.catalogs-ready` file before proceeding
   - For local development (`make run`), static files with pre-created `.catalogs-ready` are used

6. **Air-gap support**:
   - `default-dynamic-plugins-original` ConfigMap with original URLs (for image discovery)
   - Generated only if any catalog has `spec.mirror` configured

**Example:**

```yaml
apiVersion: rhdh.redhat.com/v1alpha1
kind: DevHubPluginCatalog
metadata:
  name: rhdh-1-3
spec:
  source:
    oci: registry.redhat.io/rhdh/catalog:1.3.0

  # Optional: mirror configuration for air-gap
  mirror:
    registry: internal-registry.company.com
    pathPolicies:
      - sourceRegistry: registry.redhat.io
        addPrefix: "redhat"
      - sourceRegistry: ghcr.io
        addPrefix: "github"

status:
  # Allowed values: Ready, Fetching, Failed
  phase: Ready
  lastFetched: "2026-04-15T10:30:00Z"
  pluginCount: 45
  error: "..."
```

## Alternatives Considered

### Alternative 1: Git-Synced Catalog via GitHub Workflow
- **Approach**: GitHub workflow fetches catalog from OCI and commits `dynamic-plugins.default.yaml` to git repository, operator reads from git
- **Rejected because**:
  - No way to support multiple catalogs (single synced file in repo)
  - Git repo becomes source of truth instead of OCI registry (possible version confusion)
  - Manual workflow trigger needed for catalog updates
  - Doesn't work for custom/third-party catalogs (require git access/workflow setup)

### Alternative 2: Explicit Catalog References in Backstage CR
- **Approach**: Users specify which catalogs to use in `spec.catalogs[]`
- **Rejected because**:
  - More verbose (every Backstage CR must list catalogs)
  - Breaks when new catalogs added (need to update all CRs)
  - Automatic discovery is simpler for common case
  - Can be added later if explicit control is needed

## Consequences

### Positive

✅ **Air-gap discovery**: Original URLs preserved in `-original` ConfigMap for image mirroring workflows
✅ **Multi-catalog support**: Combine RHDH catalog with custom/third-party catalogs automatically
✅ **Cluster-wide reuse**: One catalog resource serves all Backstage instances in cluster
✅ **Kubernetes-native**: Managed via kubectl, visible in cluster, follows CRD patterns
✅ **Declarative mirroring**: Mirror config in catalog spec, applied consistently
✅ **Early inspection**: Catalog content visible before any Backstage instance deployed
✅ **Status reporting**: Catalog fetch failures visible in CRD status, not buried in pod logs
✅ **Seamless local development**: `make run` works with static files, no DHPC needed for testing
✅ **Backstage controller unchanged**: Reads from default-config as before, catalog-agnostic

### Negative

❌ **Cluster-scoped permissions**: Creating catalogs requires cluster-admin or cluster-scoped RBAC (not namespace-scoped)
❌ **Version coupling**: Catalogs tied to RHDH versions (must upgrade catalogs with operator) - but it is what is used anyway
❌ **Additional CRD**: More resources to learn, manage, and troubleshoot

### Neutral

⚖️ **Automatic discovery**: All catalogs discovered automatically (no explicit references), trade-off between convenience and explicit control
⚖️ **Primary catalog guaranteed**: Operator installation includes primary catalog (reduces setup, but adds mandatory resource)
⚖️ **Single merged ConfigMap**: DHPC merges all catalogs into one ConfigMap (simpler for Backstage controller, but hides per-catalog details)
⚖️ **Readiness marker file**: `.catalogs-ready` file signals readiness (simple file-based contract between DHPC and Backstage controller)
⚖️ **Catalog immutability**: Once created, catalog content changes only via re-fetch (predictable but requires explicit refresh)

## Notes

**Related ADRs:**
- ADR-003 (Operator-Based Plugin Configuration Processing) builds on this foundation for config merging
- ADR-004 (Plugin Infrastructure Support) uses catalog ConfigMaps for image discovery

**Open questions for implementation:**
- Catalog conflict resolution: What if same plugin exists in multiple catalogs? Is it allowed at all?
- Catalog update strategy: How do catalog updates trigger Backstage instance redeployment?
