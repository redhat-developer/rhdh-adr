# ADR: OLM v1 Adoption for the RHDH Operator

## Context

**Problem**: OLM v1 GA'd in OCP 4.18, becomes the default in OCP 5, and OLM v0 is deprecated in OCP 6. The RHDH operator currently ships via OLM v0 exclusively and needs changes to support OLM v1 installation, upgrades, and testing.

The OLM team is actively encouraging early adoption. This decision is informed by a spike investigation (RHIDP-8656 under RHDHPLAN-660) that verified the RHDH operator against OLM v1 on OCP 4.21 nightly clusters.

**Spike results summary**:

| Area | Result |
|------|--------|
| Fresh install via ClusterExtension | PASS (with workarounds) |
| Integration tests | 25/26 passed (1 test-config mismatch) |
| E2E tests | 1/7 passed (6 route-delete timeouts — under investigation) |
| In-place upgrade (v1.7→v1.9) | BLOCKED by CRD upgrade safety validation |

**Who is impacted**:
- RHDH users on OCP 4.18+ who want to install via OLM v1
- RHDH users on future OCP 5.x where OLM v1 is the default
- The operator team maintaining build tooling, tests, and CRD schemas

**Constraints**:
- CRD evolution across versions (v1alpha1–v1alpha5) must pass OLM v1's CRD upgrade safety validation
- Build tooling must produce File-Based Catalog (FBC) images — OLM v1 rejects SQLite catalogs

## Decision

Adopt OLM v1 for the RHDH operator by addressing the two blockers identified during the spike:

1. **Switch to File-Based Catalog (FBC) images** — Replace the SQLite-based catalog build (`opm index add`) with FBC (`opm init` + `opm render`). OLM v1 catalogd rejects SQLite images, and FBC catalogs work with both OLM v0 (4.17+) and v1.

2. **Require v1alpha5 migration as a prerequisite for OLM v1-managed upgrades** — OLM v1 blocks upgrades when it detects type mismatches between CRD versions. Fields in v1alpha3/v1alpha4 have explicit types (`string`, `integer`, `array`) that were intentionally removed in v1alpha5. Rather than restoring deprecated fields (which contradicts ADR-005), require users on older API versions to migrate to v1alpha5 before upgrading to an OLM v1-managed operator version.

CI scripts, Helm templates, E2E tests, and other tooling that reference OLM v0 resources (CatalogSource, Subscription, OperatorGroup) will need to be updated to use OLM v1 equivalents (ClusterCatalog, ClusterExtension, ServiceAccount) as a consequence of this decision.

## Alternatives Considered

### Wait for OLM v1 to become mandatory
- **Approach**: Do nothing until OLM v0 is removed in OCP 6
- **Rejected because**: OLM v1 is already GA and will be the default in OCP 5. Waiting creates a larger migration burden and misses the window to influence OLM v1 behavior (e.g., CRD safety checks) while it is still evolving.

### Maintain separate SQLite and FBC catalog builds
- **Approach**: Keep `opm index add` for OLM v0 and add a parallel FBC build for OLM v1
- **Rejected because**: SQLite catalogs are deprecated and will be removed from `opm`. FBC catalogs work with both OLM v0 (4.17+) and OLM v1 — a single build path is simpler.

### Restore deprecated fields in v1alpha5 to pass CRD upgrade safety
- **Approach**: Add back explicit types for `image`, `replicas`, `imagePullSecrets` in v1alpha5 to match v1alpha3/v1alpha4
- **Rejected because**: These fields were intentionally deprecated and removed. Restoring them contradicts the versioning policy (ADR-005). Requiring v1alpha5 migration as a prerequisite is cleaner.

## Consequences

### Positive

✅ RHDH operator installable via OLM v1 on OCP 4.18+, ready for OCP 5 default
✅ FBC catalog images are the modern standard and work with both OLM v0 and v1
✅ Integration tests already pass (25/26) under OLM v1 with no functional regressions
✅ Single catalog build path (FBC) simplifies the build pipeline

### Negative

❌ CRD upgrade safety fix requires coordinating a v1alpha5 migration prerequisite — users on v1alpha3/v1alpha4 must migrate before upgrading to the OLM v1-supported operator version
❌ CI scripts, Helm templates, and E2E tests all need updating to use OLM v1 resources (ClusterCatalog, ClusterExtension) — significant surface area
❌ Several areas remain unverified: airgap/disconnected installs, plugin infrastructure operators (ArgoCD/Serverless/Pipelines) via OLM v1, namespace install modes (OwnNamespace/SingleNamespace), OperatorConditions absence handling, and automated CI integration

### Neutral

⚖️ The `catalogFilter` requirement is an OLM v1 behavior difference affecting all operators, not RHDH-specific
⚖️ The preflight override (`crdUpgradeSafety.enforcement: None`) remains a functional workaround for users who cannot migrate to v1alpha5 immediately, but should not be a permanent recommendation

## References

- [OLM v1 docs (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/operators/olm-v1)
- [OLM v1 design decisions](https://operator-framework.github.io/operator-controller/project/olmv1_design_decisions/)
- OLM v1 adoption Slack: [#olm-v1-adoption-for-your-operator](https://redhat.enterprise.slack.com/archives/C097W1N3UQ6)
- [OCP tracker: OCPSTRAT-2268](https://issues.redhat.com/browse/OCPSTRAT-2268)
- [OLM v1 intent-to-release](https://access.redhat.com/articles/7134648)
- [RHDH feature: RHDHPLAN-660](https://redhat.atlassian.net/browse/RHDHPLAN-660)
- [RHDH spike: RHIDP-8656](https://redhat.atlassian.net/browse/RHIDP-8656)
- [CRD version management: ADR-005](005-crd-version-management.md)
