# ADR: OLM v1 Adoption for the RHDH Operator

## Context

**Problem**: OLM v1 GA'd in OCP 4.18, becomes the default in OCP 5, and OLM v0 is deprecated in OCP 6. The RHDH operator currently ships via OLM v0 and needs to verify compatibility and identify required changes to fully support OLM v1.

The OLM team is actively encouraging early adoption via the `#olm-v1-adoption-for-your-operator` Slack channel and the upstream tracker OCPSTRAT-2268. This spike (RHIDP-8656 under RHDHPLAN-660) investigates what works today, what's broken, and what needs to change.

**Who is impacted**:
- RHDH users on OCP 4.18+ who may want to install via OLM v1
- RHDH users on future OCP 5.x where OLM v1 is the default
- The operator team who must update build tooling, test infrastructure, and CRD schemas

**Constraints**:
- Must maintain backward compatibility with OLM v0 during the transition period
- CRD evolution across versions (v1alpha1 through v1alpha5) must pass OLM v1's upgrade safety validation
- Build tooling must produce File-Based Catalog (FBC) images, not SQLite

## Verification Summary

We verified the RHDH operator (v1.9.0 from main, commit a1b48bd) against OLM v1 on OCP 4.21 nightly clusters across three areas. Full step-by-step findings with exact command output are in the supporting documents.

| Area | Result | Details |
|------|--------|---------|
| Fresh install via ClusterExtension | **PASS** (with workarounds) | [installation-findings-olmv1.md](installation-findings-olmv1.md) |
| Integration tests | **25/26 passed** | [test-suite-findings-olmv1.md](test-suite-findings-olmv1.md) |
| E2E tests | **1/7 passed** (route-delete timeouts) | [test-suite-findings-olmv1.md](test-suite-findings-olmv1.md) |
| In-place upgrade v1.7.0 to v1.9.4 | **BLOCKED** without preflight override | [upgrade-path-findings-olmv1.md](upgrade-path-findings-olmv1.md) |

### Manifests used

- [rhdh-olmv1-verification.yaml](rhdh-olmv1-verification.yaml) — ClusterCatalog + ClusterExtension for fresh install
- [rhdh-olmv1-e2e-manifest.yaml](rhdh-olmv1-e2e-manifest.yaml) — E2E test variant (deploys into `rhdh-operator` namespace to match test suite expectations)

## Decision

Adopt OLM v1 for the RHDH operator by addressing the blockers identified during verification. The following changes are required:

**Implementation approach**:

### 1. Fix the Makefile `catalog-build` target (High Priority)

The current `catalog-build` target uses `opm index add`, which produces SQLite-based catalog images. OLM v1's catalogd rejects these because they lack the required FBC label (`operators.operatorframework.io.index.configs.v1`).

Replace the SQLite workflow with an FBC workflow:
- Use `opm init` + `opm render` to generate FBC YAML
- Use a Dockerfile with `FROM scratch` and the `operators.operatorframework.io.index.configs.v1` label
- Drop the deprecated `opm index add` path

See [installation-findings-olmv1.md](installation-findings-olmv1.md) Finding 1 for the exact manual workaround and Dockerfile.

### 2. Fix CRD schema to pass upgrade safety validation (High Priority)

OLM v1's CRD upgrade safety validation blocks upgrades when it detects type changes between CRD versions. The RHDH CRD triggers this when fields in v1alpha3/v1alpha4 have explicit types (`string`, `integer`, `array`) but v1alpha5 uses reference patterns that drop the explicit type.

Specific fields flagged:
- `spec.application.image` — type "string" to ""
- `spec.application.replicas` — type "integer" to "", default "1" removed, format "int32" removed
- `spec.application.imagePullSecrets` — type "array" to ""

Options:
- **Option A**: Restore explicit types in v1alpha5 to match v1alpha3/v1alpha4 (preserves upgrade safety compatibility)
- **Option B**: Ship with `crdUpgradeSafety.enforcement: None` in documentation and recommend it to users (workaround, not ideal)
- **Option C**: Engage the OLM team to determine if these changes are genuinely breaking or if the safety check is overly strict for this pattern

See [upgrade-path-findings-olmv1.md](upgrade-path-findings-olmv1.md) for the full error output and analysis.

### 3. Update OLM v1 manifests to use `catalogFilter` (Medium Priority)

When deploying a custom-built operator alongside the default Red Hat catalogs, OLM v1 resolves across all catalogs and picks the highest semver match. Without `catalogFilter`, a custom build (e.g., `v1.9.0-dev`) loses to the published version (`v1.9.4`).

All OLM v1 manifests and deploy scripts must include `catalogFilter` in the ClusterExtension spec when targeting a custom catalog:

```yaml
spec:
  source:
    sourceType: Catalog
    catalog:
      packageName: rhdh
      catalogFilter: rhdh-custom-catalog  # required for custom catalogs
```

See [installation-findings-olmv1.md](installation-findings-olmv1.md) Finding 2.

### 4. Add namespace override to E2E test suite (Medium Priority)

The E2E test suite hardcodes `_namespace = "rhdh-operator"` for the operator namespace. OLM v1 deploys into whatever namespace is specified in `spec.namespace`. Add a `BACKSTAGE_OPERATOR_NAMESPACE` env var override so the tests work with any deployment namespace.

See [test-suite-findings-olmv1.md](test-suite-findings-olmv1.md) Finding 3.

### 5. Investigate E2E route-delete timeout failures (Medium Priority)

6 of 7 E2E tests failed on the same route-deletion timeout (`e2e_test.go:269`). All failures follow the same pattern: after patching a Backstage CR to disable the route, the route is not deleted within the 60-second timeout. This needs investigation to determine whether it's:
- An operator regression in route reconciliation
- A test timing issue (60s too short for current operator version)
- An OLM v1-specific behavior difference

Run the same E2E tests against an OLM v0 deployment on the same cluster to compare.

## Alternatives Considered

### Alternative 1: Wait for OLM v1 to become mandatory
- **Approach**: Do nothing until OLM v0 is actually removed in OCP 6
- **Rejected because**: OLM v1 is already GA in OCP 4.18+ and will be the default in OCP 5. Early adopters and the OLM team expect operators to verify compatibility now. Waiting creates a larger migration burden later and misses the opportunity to influence OLM v1's CRD safety behavior while it's still evolving.

### Alternative 2: Maintain separate OLM v0 and v1 catalog builds
- **Approach**: Keep `opm index add` (SQLite) for OLM v0 and add a parallel FBC build for OLM v1
- **Rejected because**: SQLite catalogs are deprecated and will be removed from `opm`. Moving entirely to FBC is the right path — FBC catalogs work with both OLM v0 (4.17+) and OLM v1.

## Consequences

### Positive
- RHDH operator will be installable via OLM v1 on OCP 4.18+
- FBC catalog images are the modern standard and work with both OLM v0 and v1
- Fixing the CRD schema ensures smooth upgrades without requiring users to set preflight overrides
- Integration tests already pass (25/26) under OLM v1 with no functional regressions

### Negative
- CRD schema fix requires careful coordination to maintain backward compatibility across v1alpha3/v1alpha4/v1alpha5
- E2E test suite needs updates for OLM v1 namespace flexibility
- The E2E route-delete failures need investigation before we can confirm full test parity with OLM v0

### Neutral
- The `catalogFilter` requirement is an OLM v1 behavior difference (not a bug) that affects all operators, not just RHDH
- The preflight override workaround (`crdUpgradeSafety.enforcement: None`) is functional but should be a temporary measure, not a permanent recommendation

## Not Yet Tested

The following areas were not covered in this spike and should be addressed in follow-up work:

- **Airgap/disconnected flow** — mirror registry setup and image mirroring for OLM v1
- **Plugin infrastructure dependencies** — ArgoCD, Serverless, Pipelines operators installed via OLM v1 alongside RHDH
- **Namespace install modes** — OwnNamespace and SingleNamespace modes (GA in OCP 4.21)
- **Automated CI test mode** — running OLM v1 verification as part of the CI pipeline
- **OperatorConditions absence** — OLM v1 does not create OperatorConditions objects; verify the operator handles this gracefully

## References

- [OLM v1 docs (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/operators/olm-v1)
- [OLM v1 adoption Slack: #olm-v1-adoption-for-your-operator](https://redhat.enterprise.slack.com/)
- [Upstream tracker: OCPSTRAT-2268](https://issues.redhat.com/browse/OCPSTRAT-2268)
- [OLM v1 intent-to-release](https://access.redhat.com/articles/7134648)
- [RHDH feature: RHDHPLAN-660](https://redhat.atlassian.net/browse/RHDHPLAN-660)
- [RHDH spike: RHIDP-8656](https://redhat.atlassian.net/browse/RHIDP-8656)
- Key contacts: Eugenia Gibson (PgM), Marina Kalinin (PM), Gavin Bell (EM), Joe Lanford (Staff Eng)
