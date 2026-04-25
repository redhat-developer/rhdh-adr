# ADR: CRD Version Management and Conservative API Versioning Policy

## Context

**Problem**: No clear strategy for managing CRD version lifecycle as the API evolves - how to deprecate old versions, when to increment versions, and how to handle version removal without breaking user upgrades.

As the Backstage CRD evolves, we need answers to:
- When do we increment to a new API version vs adding to existing version?
- How do we deprecate old versions without breaking upgrades?
- Can we ever remove old versions from the CRD spec?
- How do we prevent indefinite version proliferation?

**Current state:**
- Backstage CRD evolved from v1alpha1 through v1alpha5
- Previous practice: increment version for new API features (aggressive versioning)
- CRD spec growing with each version increment

**Triggering incident (v1.9.x):**
- v1alpha1 and v1alpha2 were removed from CRD spec
- Upgrade failures: "risk of data loss updating backstages.rhdh.redhat.com: new CRD removes version v1alpha1 that is listed in storedVersions"
- Emergency fix: re-added with `served: false`
- Revealed need for formal version management strategy

More context in the following JIRA issues:
- https://redhat.atlassian.net/browse/RHDHSUPP-349
- https://redhat.atlassian.net/browse/RHDHBUGS-292

**Who is impacted:**
- **Users upgrading operator**: Need seamless upgrades without manual intervention
- **Operator maintainers**: Need clarity on when to increment versions
- **API consumers**: Need stable, predictable API evolution
- **Future versions**: This decision affects v1alpha6, v1alpha7, v1beta1, etc.

**Constraints:**
- Cannot remove versions from spec if they exist in any cluster's storedVersions
- Must support seamless upgrades without manual user steps
- Must maintain API evolution flexibility
- Must prevent unbounded version proliferation
- Kubernetes validates that all storedVersions exist in CRD spec

## Decision

Adopt a conservative CRD version management strategy: keep deprecated API versions in CRD spec with `served: false` indefinitely, and only increment API version for breaking changes.

**Implementation approach:**

1. **Deprecated version handling**:
   - Keep all deprecated versions (v1alpha1, v1alpha2, etc.) in CRD spec permanently
   - Mark as `served: false, storage: false, deprecated: true`
   - Versions remain in spec but are not accessible via API
   - Allows Kubernetes to read old objects from etcd without upgrade failures

2. **New versioning policy** (major change from previous practice):
   - **Only increment API version for breaking changes**
   - Compatible additions (new optional fields, relaxed validation) added to current version
   - Aligns with Kubernetes API conventions (e.g., Pod v1 stable since 2015)

3. **Version increment criteria** (following Kubernetes API guidelines):

   **Stay on same version (compatible changes):**
   - Add new optional field
   - Add new enum value
   - Add new status field
   - Make required field optional
   - Relax validation constraints

   **Increment to new version (breaking changes):**
   - Remove field
   - Rename field
   - Change field type
   - Make optional field required
   - Remove enum value
   - Tighten validation constraints

**Example CRD structure:**
```yaml
spec:
  versions:
    - name: v1alpha1
      served: false      # Not accessible via API
      storage: false
      deprecated: true
    - name: v1alpha2
      served: false
      storage: false
      deprecated: true
    - name: v1alpha3
      served: true
      storage: false
    - name: v1alpha4
      served: true
      storage: false
    - name: v1alpha5
      served: true
      storage: true       # Current storage version
```

**Version evolution example (just illustration, not a plan!):**
```
Operator v1.10 → v1alpha5 (current)
Operator v2.0  → v1alpha5 (add dynamic-plugins related fields - compatible)
Operator v2.1  → v1alpha5 (add app-config related fields - compatible)
Operator v2.2  → v1alpha5 (add RBAC fields - compatible)
...
Operator v3.0  → v1alpha6 (only when breaking change actually needed)
```

## Alternatives Considered

### Alternative 1: Conversion Webhooks
- **Approach**: Deploy webhook server to handle automatic conversion between API versions, allowing removal of old versions from CRD spec even if they remain in storedVersions
- **Rejected because**:
  - Significant infrastructure complexity (Service, TLS certificates, webhook server deployment)
  - ~100-200 lines of code boilerplate per version for conversion functions
  - Additional testing and debugging surface
  - Overkill for conservative API evolution (cost not justified by removing ~20 lines of YAML)
  - Webhook is industry standard for complex APIs, but RHDH API evolution is conservative
  - Can reconsider if we accumulate 15+ versions

### Alternative 2: Storage Migration (kubectl plugin or StorageVersionMigration controller)
- **Approach**: Use external tool to rewrite all CRs to current storage version, cleaning storedVersions before operator upgrade
- **Rejected because**:
  - Requires external tool installation (kubectl krew plugin) or controller deployment
  - Manual user action before each operator upgrade
  - Upgrade failures if users forget migration step (safe failure, but creates support burden)
  - Affects ~5-10% of users with old storedVersions
  - Pushes complexity to users rather than handling automatically
  - Doesn't prevent future version proliferation

## Consequences

### Positive

✅ **Zero upgrade friction**: 100% upgrade success rate, no manual user intervention required
✅ **Zero infrastructure complexity**: No webhook servers, certificates, or conversion logic needed
✅ **Zero risk**: Cannot cause data loss or upgrade failures
✅ **Follows Kubernetes practice**: Core APIs (Pod, Service, etc.) keep old versions indefinitely
✅ **Prevents version proliferation**: New policy reduces unnecessary version increments
✅ **Future flexibility**: Can still add breaking changes when genuinely needed (increment to v1alpha6+)
✅ **API evolution clarity**: Clear, documented guidelines for when to increment vs extend existing version
✅ **Graduation path preserved**: Can move to v1beta1 or v1 when API stabilizes

### Negative

❌ **CRD spec contains deprecated versions**: ~12 lines of YAML per deprecated version permanently in spec
❌ **Perception of bloat**: CRD appears "cluttered" with historical versions (though cost is negligible)

### Neutral

⚖️ **Policy shift required**: Team must adopt new versioning discipline (compatible additions stay on same version)
⚖️ **Future webhook consideration**: If CRD reaches 15+ versions, may reconsider webhook investment as cleanup mechanism
⚖️ **Not industry standard for complex APIs**: Many operators use webhooks, but justified for conservative evolution
⚖️ **Version count grows slowly**: Only increments for breaking changes, not feature additions

## Notes

**Cost-benefit analysis:**
- Webhook approach: Significant infrastructure + code → Removes ~20 lines from CRD spec
- `served: false` approach: Zero effort → Keeps ~20 lines in CRD spec
- For an operator with conservative API evolution, simplicity wins

**Real-world precedent:**
- Kubernetes Pod API: Still `v1` since 2015 despite hundreds of field additions (all backward-compatible)
- Many Kubernetes core resources keep deprecated versions indefinitely in their specs

**Future considerations:**
- **If API stabilizes**: Consider graduating to v1beta1 or v1
- **If many breaking changes accumulate**: Reconsider webhook or storage migration approaches
- **If CRD reaches 15+ versions**: Cleanup might justify webhook investment

**References:**
- Kubernetes API changes guide: https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api_changes.md
- CRD versioning: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Storage migrator: https://github.com/kubernetes-sigs/kube-storage-version-migrator
- OpenShift storage migration: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/storage_apis/storageversionmigration-migration-k8s-io-v1alpha1
