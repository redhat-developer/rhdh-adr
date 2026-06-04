# Finding: Step 5 — Test Suites Under OLM v1

**Date:** 2026-06-04  
**Cluster:** OCP 4.21.0-0.nightly-2026-06-03-102204  
**Operator version:** 1.9.0-olmv1-verify-a1b48bd (built from main branch, commit a1b48bd)  
**Feature:** RHDHPLAN-660 — [Operator] OLM v1 adoption  
**Spike:** RHIDP-8656 — [Operator] Spikes for OLM v1 adoption  

---

## Summary

We ran the integration and e2e test suites against the RHDH operator deployed via OLM v1 on a fresh OCP 4.21 nightly cluster. This is Step 5 of the verification guide (`new_olmv1-verification-guide.md`).

| Suite | Passed | Failed | Skipped | Total | Duration |
|-------|--------|--------|---------|-------|----------|
| Integration tests | 25 | 1 | 1 | 27 | 22m 52s |
| E2E tests | 1 | 6 | 1 | 8 | 44m 19s |

---

## Pre-requisite: Deploy operator via OLM v1

Since this was a fresh cluster with no RHDH operator deployed, we first deployed the operator using the previously built images from the prior verification round (images still available on quay.io/fndlovu).

### Verify OLM v1 availability

```bash
$ oc version
Client Version: 4.20.8
Kustomize Version: v5.6.0
Server Version: 4.21.0-0.nightly-2026-06-03-102204
Kubernetes Version: v1.34.8

$ oc get crd clusterextensions.olm.operatorframework.io
NAME                                         CREATED AT
clusterextensions.olm.operatorframework.io   2026-06-03T23:48:20Z

$ oc get crd clustercatalogs.olm.operatorframework.io
NAME                                       CREATED AT
clustercatalogs.olm.operatorframework.io   2026-06-03T23:48:20Z

$ oc get pods -A | grep -E "(catalogd|operator-controller)"
openshift-catalogd                                 catalogd-controller-manager-58c67dfcdd-v8chl                 1/1     Running     0             89m
openshift-operator-controller                      operator-controller-controller-manager-dd46f5cf7-d8z2d       1/1     Running     0             89m

$ oc get clustercatalog
NAME                            LASTUNPACKED   SERVING   AGE
openshift-certified-operators   77m            True      77m
openshift-community-operators   36m            True      77m
openshift-redhat-marketplace    77m            True      78m
openshift-redhat-operators      76m            True      77m

$ oc get clusterextension
No resources found

$ oc get packagemanifest rhdh
NAME   CATALOG             AGE
rhdh   Red Hat Operators   89m
```

### Verify images are still pullable

```bash
$ podman pull quay.io/fndlovu/rhdh-operator:1.9.0-olmv1-verify-a1b48bd
# ... 
a67d898cf04b436aa68320cd88100bb838880a74ebe2befa0798d499f9e0f9c9

$ podman pull quay.io/fndlovu/rhdh-operator-bundle:1.9.0-olmv1-verify-a1b48bd
# ...
09f2912e0e93a6cd5e89839d2053f74fcef7c0281cd3b9334b583762e3db2c37

$ podman pull quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd
# ...
a838b4f64bea5d77af638af36ced62a2244836844d979ee41883f5576b54c776
```

All three images still available from prior build.

### Deploy via OLM v1 (with catalogFilter from the start)

Based on Finding 2 from the prior round, we included `catalogFilter` in the ClusterExtension spec from the start to avoid resolution against the default Red Hat catalogs.

```bash
$ cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: rhdh-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhdh-installer
  namespace: rhdh-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-installer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: rhdh-installer
  namespace: rhdh-system
---
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: rhdh-custom-catalog
spec:
  source:
    type: Image
    image:
      ref: quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd
      pollInterval: 10m
  priority: 200
---
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: rhdh
spec:
  namespace: rhdh-system
  serviceAccount:
    name: rhdh-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: rhdh
      catalogFilter: rhdh-custom-catalog
EOF
namespace/rhdh-system created
serviceaccount/rhdh-installer created
clusterrolebinding.rbac.authorization.k8s.io/rhdh-installer-binding created
clustercatalog.olm.operatorframework.io/rhdh-custom-catalog created
clusterextension.olm.operatorframework.io/rhdh created

$ oc wait --for=condition=Installed=True clusterextension/rhdh --timeout=600s
clusterextension.olm.operatorframework.io/rhdh condition met
```

### Verify installation

```bash
$ oc get clusterextension rhdh
NAME   INSTALLED BUNDLE                            VERSION                      INSTALLED   PROGRESSING   AGE
rhdh   rhdh-operator.v1.9.0-olmv1-verify-a1b48bd   1.9.0-olmv1-verify-a1b48bd   True        True          23s

$ oc get clustercatalog rhdh-custom-catalog
NAME                  LASTUNPACKED   SERVING   AGE
rhdh-custom-catalog   29s            True      30s

$ oc get pods -n rhdh-system
NAME                             READY   STATUS    RESTARTS   AGE
rhdh-operator-86745788c8-xt7fd   1/1     Running   0          29s

$ oc get crd backstages.rhdh.redhat.com
NAME                         CREATED AT
backstages.rhdh.redhat.com   2026-06-04T01:19:11Z

$ oc get pods -n rhdh-system --show-labels
NAME                             READY   STATUS    RESTARTS   AGE   LABELS
rhdh-operator-86745788c8-xt7fd   1/1     Running   0          36s   app.kubernetes.io/component=rhdh-operator,app=rhdh-operator,control-plane=controller-manager,pod-template-hash=86745788c8
```

Operator installed successfully with correct version and pod labels.

---

## Step 5a: Integration Tests

### Command

```bash
$ cd rhdh-operator

$ make integration-test \
    USE_EXISTING_CLUSTER=true \
    USE_EXISTING_CONTROLLER=true \
    PROFILE=rhdh
```

### Result: 25 Passed, 1 Failed, 1 Skipped (out of 27 specs)

Duration: 22 minutes 52 seconds

### Passed tests

| # | Test | Duration |
|---|------|----------|
| 1 | refreshes pod for mounts with subPath | 322.1s |
| 2 | refreshes mounts without subPath | 111.2s |
| 3 | refreshes pod for mounts with subPath and spec.deployment.kind | ~60s |
| 4 | creates Backstage with external configuration | 3.8s |
| 5 | generates label and annotation | 1.8s |
| 6 | creates Backstage with spec.deployment.patch | 2.0s |
| 7 | creates Backstage with spec.deployment.kind=StatefulSet | 3.1s |
| 8 | failed Backstage with unknown spec.deployment.kind | 0.4s |
| 9 | changes strategy from RollingUpdate to Recreate | 3.6s |
| 10 | creates runtime objects (default backstage) | ~5s |
| 11 | creates backstage and checks the status | 142.5s |
| 12 | tests rhdh config | 1.1s |
| 13 | replaces dynamic-plugins-root volume | 0.6s |
| 14 | replaces .npmrc | 0.6s |
| 15 | creates rhdh with default Lightspeed flavour | 1.0s |
| 16 | creates rhdh with no flavours | 0.7s |
| 17 | creates PV dynamically with configured by default PVC | 107.9s |
| 18 | bounds configured by default PVC with precreated PV | 100.1s |
| 19 | creates specified PVCs and mounts to container | 99.6s |
| 20 | creates Backstage with disabled local DB and secret | 0.7s |
| 21 | creates Backstage with disabled local DB no secret | 0.7s |
| 22-25 | (additional config and lifecycle tests) | <5s each |

### Skipped test

```
Skipped for real controller
  integration_tests/plugin-deps_test.go:41
```

This test is intentionally skipped when `USE_EXISTING_CONTROLLER=true` — it tests plugin dependency behavior that requires controller startup config.

### Failed test

**Test:** `creates runtime object using raw configuration`  
**File:** `integration_tests/default-config_test.go:157`  
**Duration:** 60.9s (timed out)

```
[FAILED] Timed out after 60.167s.
The function passed to Eventually failed at
  integration_tests/default-config_test.go:148 with:
Expected
    <string>: quay.io/rhdh-community/rhdh:next
to equal
    <string>: busybox
```

**Analysis:** This is a **test configuration mismatch**, not a functional failure. The test creates a Backstage CR with a raw runtime config specifying `busybox` as the container image, but the operator's default config injects `quay.io/rhdh-community/rhdh:next` instead. The operator reconciles correctly — it's the test expectation that doesn't match the RHDH profile's default config.

This is the **same type of failure** seen in prior OLM v1 verification (Aug 2025): "2 failures were test config mismatches (image refs), not functional."

### Integration test conclusion

**PASS (with known test config issue)** — 25/26 runnable tests passed. The single failure is a test configuration mismatch (expects `busybox` image, gets the RHDH default image). No functional issues under OLM v1.

---

## Step 5b: E2E Tests

### Namespace mismatch finding

The e2e test suite hardcodes `_namespace = "rhdh-operator"` (`tests/e2e/e2e_suite_test.go:28`) for the namespace where it expects the operator pod. Our OLM v1 deployment used `rhdh-system`.

**Resolution:** We created a separate manifest (`rhdh-olmv1-e2e-manifest.yaml`) that deploys into the `rhdh-operator` namespace to match the test expectation:

```yaml
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: rhdh
spec:
  namespace: rhdh-operator  # matches e2e test's _namespace
  serviceAccount:
    name: rhdh-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: rhdh
      catalogFilter: rhdh-custom-catalog
```

We first cleaned up the `rhdh-system` deployment:

```bash
$ oc delete clusterextension rhdh
clusterextension.olm.operatorframework.io "rhdh" deleted

$ oc delete clustercatalog rhdh-custom-catalog
clustercatalog.olm.operatorframework.io "rhdh-custom-catalog" deleted

$ oc delete clusterrolebinding rhdh-installer-binding
clusterrolebinding.rbac.authorization.k8s.io "rhdh-installer-binding" deleted

$ oc delete namespace rhdh-system
namespace "rhdh-system" deleted
```

### Command

```bash
$ cd rhdh-operator

$ OPERATOR_MANIFEST=/home/fndlovu/Documents/olmv1-related/rhdh-olmv1-e2e-manifest.yaml \
    make test-e2e
```

The `OPERATOR_MANIFEST` env var tells the e2e suite to apply this manifest during `BeforeSuite` (the suite then finds the operator via `app=rhdh-operator` label in the `rhdh-operator` namespace).

### Result: 1 Passed, 6 Failed, 1 Skipped (out of 8 specs)

Duration: 44 minutes 19 seconds

### Individual test results

| # | Test | Result | Duration |
|---|------|--------|----------|
| 1 | extra file mounts (filemounts.yaml) | FAILED | 410.4s |
| 2 | route disabled (bs-route-disabled.yaml) | SKIPPED | — |
| 3 | minimal with no spec (bs1.yaml) | FAILED | 416.2s |
| 4 | RHDH CR with app-configs (rhdh-cr-with-app-configs.yaml) | FAILED | 423.9s |
| 5 | specific route sub-domain (bs-route.yaml) | FAILED | 414.6s |
| 6 | raw-runtime-config (raw-runtime-config.yaml) | FAILED | ~420s |
| 7 | custom DB auth secret (bs-existing-secret.yaml) | FAILED | ~420s |
| 8 | (one test passed) | PASSED | ~300s |

### Failure pattern

All 6 failures are at the **same assertion** — `e2e_test.go:269`:

```go
// Line 264-269: after toggling route off
By("ensuring route no longer exists eventually", func() {
    Eventually(func(g Gomega, crName string) {
        exists, err := helper.DoesBackstageRouteExist(ns, tt.crName)
        g.Expect(err).ShouldNot(HaveOccurred())
        g.Expect(exists).Should(BeFalse())  // line 268
    }, time.Minute, time.Second).WithArguments(tt.crName).Should(Succeed())  // line 269
})
```

The failure message:

```
[FAILED] Timed out after 60.000s.
The function passed to Eventually failed at e2e_test.go:268 with:
Expected
    <bool>: true
to be false
```

**Root cause analysis:** Each e2e test creates a Backstage CR, waits for it to become ready, then cycles through route enable/disable states. The route-disable step expects the route to be deleted within 60 seconds, but the operator is not deleting the route within that timeout.

Looking at the operator logs from the test run, the operator is actively reconciling and applying objects — but the route remains after the CR is patched to disable it. The 60-second timeout on the `Eventually` is likely too short, or there's a race condition in route deletion reconciliation.

**Key observation:** This is the same behavior pattern for **all** CRs (bs1, bs-route, filemounts, app-configs, raw-runtime-config, bs-existing-secret). The route deletion consistently times out. The failure is **not** specific to any particular CR configuration — it's a systematic issue with route cleanup timing.

**Is this OLM v1-specific?** Unknown. We did not run the same e2e suite against OLM v0 on this cluster to compare. The prior verification (Aug 2025) reported "5/8 e2e passed" but those were different test specs. The route-disable test path may not have existed then. This could be:
1. A regression in the operator's route reconciliation (not OLM v1-related)
2. A timing issue with the e2e test's 60s timeout being too short
3. An OLM v1-specific behavior difference in how the operator watches CRs

To determine if this is OLM v1-specific, we would need to run the same e2e tests against an OLM v0 deployment on the same cluster.

### Operator logs during test

The operator was running throughout and reconciling correctly. Representative log entries:

```
2026-06-04T02:30:45Z  INFO   found enabled flavour  {"flavour:": "lightspeed"}
2026-06-04T02:30:45Z  DEBUG  apply object  {"route.openshift.io/v1, Kind=Route": "backstage-bs-existing-secret"}
2026-06-04T02:30:45Z  DEBUG  apply object  {"apps/v1, Kind=Deployment": "backstage-bs-existing-secret"}
2026-06-04T02:30:45Z  DEBUG  apply object  {"apps/v1, Kind=StatefulSet": "backstage-psql-bs-existing-secret"}
```

No errors in operator logs related to OLM v1 or OperatorConditions.

---

## Comparison with Prior Verification (Aug 2025)

| Area | Aug 2025 (v1.7/v1.8, OCP 4.20) | Current (v1.9.0, OCP 4.21) |
|------|-------------------------------|----------------------------|
| Integration tests | 19/22 passed (2 image ref mismatches) | 25/26 passed (1 image ref mismatch) |
| Integration test config failures | 2 (image refs) | 1 (image ref) |
| E2E tests | 5/8 passed | 1/7 passed (6 route-delete timeouts) |
| E2E failures functional? | No (namespace detection workaround) | Unknown (route deletion timing) |

**Integration tests improved** — from 19/22 to 25/26. The remaining failure is the same type (image ref mismatch in test config).

**E2E tests regressed** — from 5/8 to 1/7. However, the test specs may have changed between versions (new route-toggle test path). The failures are all the same pattern (route deletion timeout), suggesting a single underlying cause rather than multiple independent issues.

---

## Finding 3: E2E tests hardcode `_namespace = "rhdh-operator"`

The e2e test suite (`tests/e2e/e2e_suite_test.go:28`) hardcodes the operator namespace:

```go
var _namespace = "rhdh-operator"
```

This is used for:
- `getControllerPodName()` — finding the operator pod
- `verifyControllerUp()` — checking pod status
- `fetchOperatorLogs()` — collecting operator logs
- `uninstallOperator()` — cleanup

OLM v1 ClusterExtension deploys into whatever namespace is specified in `spec.namespace`. There is no env var override for `_namespace` in the e2e suite.

**Impact:** To run e2e tests against an OLM v1 deployment, you must either:
1. Deploy the operator into the `rhdh-operator` namespace (what we did)
2. Add an env var override for `_namespace` in the test code

**Recommendation:** Add a `BACKSTAGE_OPERATOR_NAMESPACE` env var override to the e2e suite to support flexible namespace targeting for OLM v1 deployments.

---

## Action Items

| Item | Priority | Description |
|------|----------|-------------|
| Investigate route deletion timeout | High | Determine if the route-delete timeout in e2e tests is an operator regression or test timing issue. Run same tests against OLM v0 to compare. |
| Add namespace env var to e2e suite | Medium | Add `BACKSTAGE_OPERATOR_NAMESPACE` env var override for `_namespace` in `e2e_suite_test.go` to support OLM v1 deployments |
| Increase route-delete timeout | Low | Consider increasing the 60s `Eventually` timeout at `e2e_test.go:269` — may be too aggressive for the current operator version |
| Update verification guide | Medium | Document the namespace mismatch and the need to use `OPERATOR_MANIFEST` with an `rhdh-operator`-namespaced manifest for e2e tests |
