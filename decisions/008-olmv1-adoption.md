# ADR: OLM v1 Adoption for the RHDH Operator

## Context

**Problem**: OLM v1 GA'd in OCP 4.18, becomes the default in OCP 5, and OLM v0 is deprecated in OCP 6. The RHDH operator currently ships via OLM v0 exclusively and needs changes to support OLM v1 installation, upgrades, and testing.

The OLM team is actively encouraging early adoption. This decision is informed by a spike investigation (RHIDP-8656 under RHDHPLAN-660) that verified the RHDH operator against OLM v1 on OCP 4.21 nightly clusters.

**Spike results summary**:

| Area | Result |
|------|--------|
| Fresh install via ClusterExtension | PASS (required FBC catalog and catalog selector pinning) |
| Integration tests | 25/26 passed (1 test-config mismatch) |
| E2E tests | 1/7 passed (6 route-delete timeouts — under investigation) |
| In-place upgrade (v1.7→v1.9) | BLOCKED by CRD upgrade safety validation (OLM v1 bug — fixed upstream in OCP 4.22) |

**Who is impacted**:
- RHDH users on OCP 4.18+ who want to install via OLM v1
- RHDH users on future OCP 5.x where OLM v1 is the default
- The operator team maintaining build tooling, tests, and CRD schemas

**Constraints**:
- Build tooling must produce File-Based Catalog (FBC) images — OLM v1 rejects SQLite catalogs

## Decision

Adopt OLM v1 for the RHDH operator:

1. **Switch to File-Based Catalog (FBC) images** — Replace the SQLite-based catalog build (`opm index add`) with FBC (`opm init` + `opm render`). OLM v1 catalogd rejects SQLite images, and FBC catalogs work with both OLM v0 (4.17+) and v1.

2. **Re-verify CRD upgrade path on OCP 4.22+** — The upgrade failure from the spike was an upstream OLM v1 bug ([OCPBUGS-60693](https://issues.redhat.com/browse/OCPBUGS-60693)), now fixed. Re-run the upgrade test on a cluster with the fix to confirm no RHDH-side changes are needed.

CI scripts, Helm templates, E2E tests, and other tooling that reference OLM v0 resources (CatalogSource, Subscription, OperatorGroup) will need to be updated to use OLM v1 equivalents (ClusterCatalog, ClusterExtension, ServiceAccount) as a consequence of this decision.

## Alternatives Considered

### Wait for OLM v1 to become mandatory
- **Approach**: Do nothing until OLM v0 is removed in OCP 6
- **Rejected because**: OLM v1 is already GA and will be the default in OCP 5. Waiting creates a larger migration burden and misses the window to influence OLM v1 behavior (e.g., CRD safety checks) while it is still evolving.

### Maintain separate SQLite and FBC catalog builds
- **Approach**: Keep `opm index add` for OLM v0 and add a parallel FBC build for OLM v1
- **Rejected because**: SQLite catalogs are deprecated and will be removed from `opm`. FBC catalogs work with both OLM v0 (4.17+) and OLM v1 — a single build path is simpler.

## Consequences

### Positive

✅ RHDH operator installable via OLM v1 on OCP 4.18+, ready for OCP 5 default
✅ FBC catalog images are the modern standard and work with both OLM v0 and v1
✅ Integration tests already pass (25/26) under OLM v1 with no functional regressions
✅ Single catalog build path (FBC) simplifies the build pipeline

### Negative

❌ CI scripts, Helm templates, and E2E tests all need updating to use OLM v1 resources (ClusterCatalog, ClusterExtension) — significant surface area
❌ Several areas remain unverified: airgap/disconnected installs, plugin infrastructure operators (ArgoCD/Serverless/Pipelines) via OLM v1, namespace install modes (OwnNamespace/SingleNamespace), OperatorConditions absence handling, and automated CI integration

### Neutral

⚖️ FBC catalogs require OCP 4.17+ — no change from the current support matrix

## References

- [OLM v1 docs (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/operators/olm-v1)
- [OLM v1 design decisions](https://operator-framework.github.io/operator-controller/project/olmv1_design_decisions/)
- OLM v1 adoption Slack: [#olm-v1-adoption-for-your-operator](https://redhat.enterprise.slack.com/archives/C097W1N3UQ6)
- [OCP tracker: OCPSTRAT-2268](https://issues.redhat.com/browse/OCPSTRAT-2268)
- [OLM v1 intent-to-release](https://access.redhat.com/articles/7134648)
- [RHDH feature: RHDHPLAN-660](https://redhat.atlassian.net/browse/RHDHPLAN-660)
- [RHDH spike: RHIDP-8656](https://redhat.atlassian.net/browse/RHIDP-8656)
- [crdify CI integration: RHIDP-8670](https://redhat.atlassian.net/browse/RHIDP-8670)
