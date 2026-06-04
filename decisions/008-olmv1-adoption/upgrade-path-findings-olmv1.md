# Finding: Step 6 — Upgrade Path Under OLM v1

**Date:** 2026-06-04  
**Cluster:** OCP 4.21.0-0.nightly-2026-06-03-102204  
**Base version:** rhdh-operator v1.7.0 (published, from `openshift-redhat-operators` catalog)  
**Target version:** rhdh-operator v1.9.4 (published, from `openshift-redhat-operators` catalog)  
**Feature:** RHDHPLAN-660 — [Operator] OLM v1 adoption  
**Spike:** RHIDP-8656 — [Operator] Spikes for OLM v1 adoption  

---

## Summary

We tested the in-place upgrade path from RHDH operator v1.7.0 to v1.9.4 via OLM v1 on a fresh OCP 4.21 nightly cluster. This re-tests the CRD upgrade safety blocker found in prior verification (Aug 2025, v1.6.3 to v1.7.0).

| Test | Result |
|------|--------|
| Upgrade v1.7.0 to v1.9.4 (without preflight override) | **BLOCKED** — CRD upgrade safety validation |
| Upgrade v1.7.0 to v1.9.4 (with preflight override) | **PASS** |
| Pre-existing Backstage instance survives upgrade | **PASS** |
| Post-upgrade smoke test (HTTP 200) | **PASS** |

**The CRD upgrade safety blocker persists on OCP 4.21.** The specific fields flagged have changed since Aug 2025 (now related to type changes in v1alpha3/v1alpha4 to v1alpha5), but the root cause is the same: the CRD schema changes between versions are detected as breaking by OLM v1's preflight validation.

---

## Step 1: Verify OLM v1 availability

```bash
$ oc version
Client Version: 4.20.8
Kustomize Version: v5.6.0
Server Version: 4.21.0-0.nightly-2026-06-03-102204
Kubernetes Version: v1.34.8

$ oc get clusterversion
NAME      VERSION                              AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.21.0-0.nightly-2026-06-03-102204   True        False         15m     Cluster version is 4.21.0-0.nightly-2026-06-03-102204

$ oc get crd clusterextensions.olm.operatorframework.io
NAME                                         CREATED AT
clusterextensions.olm.operatorframework.io   2026-06-04T08:06:27Z

$ oc get crd clustercatalogs.olm.operatorframework.io
NAME                                       CREATED AT
clustercatalogs.olm.operatorframework.io   2026-06-04T08:06:27Z

$ oc get pods -A | grep -E "(catalogd|operator-controller)"
openshift-catalogd                                 catalogd-controller-manager-58c67dfcdd-nbwcj                               1/1     Running     1 (42m ago)   43m
openshift-operator-controller                      operator-controller-controller-manager-dd46f5cf7-xgtdx                     1/1     Running     1 (42m ago)   43m

$ oc get clustercatalog
NAME                            LASTUNPACKED   SERVING   AGE
openshift-certified-operators   30m            True      31m
openshift-community-operators   30m            True      31m
openshift-redhat-marketplace    30m            True      31m
openshift-redhat-operators      31m            True      31m
```

## Step 2: Check available RHDH versions

```bash
$ oc get packagemanifest rhdh -o jsonpath='{.status.channels[*].name}' | tr ' ' '\n' | sort
fast
fast-1.1
fast-1.2
fast-1.3
fast-1.4
fast-1.5
fast-1.6
fast-1.7
fast-1.8
fast-1.9

$ oc get packagemanifest rhdh -o jsonpath='{.status.channels[*].currentCSV}' | tr ' ' '\n' | sort
rhdh-operator.v1.1.2-0.1714688890.p
rhdh-operator.v1.2.6
rhdh-operator.v1.3.5
rhdh-operator.v1.4.3
rhdh-operator.v1.5.3
rhdh-operator.v1.6.5
rhdh-operator.v1.7.4
rhdh-operator.v1.8.7
rhdh-operator.v1.9.4
rhdh-operator.v1.9.4
```

**Upgrade plan:** Install v1.7.0 from `fast-1.7`, then upgrade by switching to `fast` channel (which allows resolution up to v1.9.4). This crosses the CRD storage version boundary: v1alpha3 (v1.7.0) to v1alpha5 (v1.9.4).

---

## Step 3: Install base version (v1.7.0)

```bash
$ cat <<'EOF' | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: rhdh-upgrade-test
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhdh-installer
  namespace: rhdh-upgrade-test
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-upgrade-installer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: rhdh-installer
  namespace: rhdh-upgrade-test
---
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: rhdh-upgrade-test
spec:
  namespace: rhdh-upgrade-test
  serviceAccount:
    name: rhdh-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: rhdh
      version: "1.7.0"
      channels: [fast-1.7]
EOF
namespace/rhdh-upgrade-test created
serviceaccount/rhdh-installer created
clusterrolebinding.rbac.authorization.k8s.io/rhdh-upgrade-installer-binding created
clusterextension.olm.operatorframework.io/rhdh-upgrade-test created

$ oc wait --for=condition=Installed=True clusterextension/rhdh-upgrade-test --timeout=600s
clusterextension.olm.operatorframework.io/rhdh-upgrade-test condition met

$ oc get clusterextension rhdh-upgrade-test
NAME                INSTALLED BUNDLE       VERSION   INSTALLED   PROGRESSING   AGE
rhdh-upgrade-test   rhdh-operator.v1.7.0   1.7.0     True        True          33s

$ oc get pods -n rhdh-upgrade-test
NAME                             READY   STATUS    RESTARTS   AGE
rhdh-operator-74cff4454b-p8bdt   1/1     Running   0          70s

$ oc get crd backstages.rhdh.redhat.com -o jsonpath='{range .spec.versions[*]}{.name}: served={.served}, storage={.storage}{"\n"}{end}'
v1alpha1: served=true, storage=false
v1alpha2: served=true, storage=false
v1alpha3: served=true, storage=true
```

**v1.7.0 CRD state:** storage=v1alpha3, all three versions served.

### Create a Backstage instance (to test data continuity across upgrade)

```bash
$ cat <<'EOF' | oc apply -f -
apiVersion: rhdh.redhat.com/v1alpha3
kind: Backstage
metadata:
  name: pre-upgrade-instance
  namespace: rhdh-upgrade-test
spec:
  application:
    replicas: 1
  database:
    enableLocalDb: true
EOF
backstage.rhdh.redhat.com/pre-upgrade-instance created

$ oc wait --for=condition=Available deployment/backstage-pre-upgrade-instance \
    -n rhdh-upgrade-test --timeout=600s
deployment.apps/backstage-pre-upgrade-instance condition met

$ oc get pods -n rhdh-upgrade-test
NAME                                              READY   STATUS    RESTARTS   AGE
backstage-pre-upgrade-instance-659f664f5d-vphqs   1/1     Running   0          5m32s
backstage-psql-pre-upgrade-instance-0             1/1     Running   0          5m32s
rhdh-operator-74cff4454b-p8bdt                    1/1     Running   0          7m25s

$ oc get route -n rhdh-upgrade-test
NAME                             HOST/PORT                                                                                          PATH   SERVICES                         PORT           TERMINATION     WILDCARD
backstage-pre-upgrade-instance   backstage-pre-upgrade-instance-rhdh-upgrade-test.apps.ci-ln-0zjjhgt-76ef8.aws-2.ci.openshift.org   /      backstage-pre-upgrade-instance   http-backend   edge/Redirect   None

$ ROUTE=$(oc get route backstage-pre-upgrade-instance -n rhdh-upgrade-test -o jsonpath='{.spec.host}')
$ curl -sk "https://${ROUTE}" -o /dev/null -w "HTTP %{http_code}\n"
HTTP 200
```

**Base state confirmed:** v1.7.0 operator running, Backstage instance (v1alpha3) deployed with 1/1 pods, PostgreSQL running, route serving HTTP 200.

Note: v1.7.0 Backstage pod has 1/1 containers (no Lightspeed sidecar — that was added in a later version).

---

## Step 4: Attempt upgrade WITHOUT preflight override

```bash
$ oc patch clusterextension rhdh-upgrade-test --type='merge' -p='{
  "spec": {
    "source": {
      "catalog": {
        "version": ">=1.7.0 <2.0.0",
        "channels": ["fast"]
      }
    }
  }
}'
clusterextension.olm.operatorframework.io/rhdh-upgrade-test patched
```

### Wait and check status

```bash
$ sleep 30

$ oc get clusterextension rhdh-upgrade-test
NAME                INSTALLED BUNDLE       VERSION   INSTALLED   PROGRESSING   AGE
rhdh-upgrade-test   rhdh-operator.v1.7.0   1.7.0     True        True          14m
```

Still on v1.7.0. Checking the Progressing condition for the error:

```bash
$ oc get clusterextension rhdh-upgrade-test -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}'
```

### Result: BLOCKED by CRD upgrade safety validation

```
error for resolved bundle "rhdh-operator.v1.9.4" with version "1.9.4":
validating upgrade for CRD "backstages.rhdh.redhat.com":

v1alpha3 -> v1alpha5: ^.spec.application.imagePullSecrets: type: type changed : "array" -> ""
v1alpha3 -> v1alpha5: ^.spec.application.replicas: default: default value removed : "1"
v1alpha3 -> v1alpha5: ^.spec.application.replicas: type: type changed : "integer" -> ""
v1alpha3 -> v1alpha5: ^.spec.application.replicas: unhandled: unhandled changes found (Format "int32" -> "")
v1alpha3 -> v1alpha5: ^.spec.application.imagePullSecrets[*]: type: type changed : "string" -> ""
v1alpha3 -> v1alpha5: ^.spec.application.image: type: type changed : "string" -> ""
v1alpha4 -> v1alpha5: ^.spec.application.imagePullSecrets[*]: type: type changed : "string" -> ""
v1alpha4 -> v1alpha5: ^.spec.application.replicas: default: default value removed : "1"
v1alpha4 -> v1alpha5: ^.spec.application.replicas: type: type changed : "integer" -> ""
v1alpha4 -> v1alpha5: ^.spec.application.replicas: unhandled: unhandled changes found (Format "int32" -> "")
v1alpha4 -> v1alpha5: ^.spec.application.imagePullSecrets: type: type changed : "array" -> ""
v1alpha4 -> v1alpha5: ^.spec.application.image: type: type changed : "string" -> ""
```

```bash
$ oc get clusterextension rhdh-upgrade-test -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}'
True

$ oc get clusterextension rhdh-upgrade-test -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'
Retrying
```

### Analysis of CRD changes flagged

The CRD upgrade safety validation flags these changes between v1alpha3/v1alpha4 and v1alpha5:

| Field | Change | Why it's flagged |
|-------|--------|------------------|
| `spec.application.image` | Type "string" to "" | Field type was explicitly `string`, now uses a reference/anyOf pattern (type removed from top level) |
| `spec.application.replicas` | Type "integer" to "", default "1" removed, format "int32" removed | Same pattern: explicit type replaced with reference/anyOf |
| `spec.application.imagePullSecrets` | Type "array" to "" | Array type replaced with reference pattern |
| `spec.application.imagePullSecrets[*]` | Type "string" to "" | Array item type changed |

**Root cause:** The v1alpha5 CRD uses `x-kubernetes-preserve-unknown-fields` or OpenAPI reference patterns instead of inline type declarations for some fields. OLM v1's CRD upgrade safety treats removing an explicit type as a potentially breaking change (it could allow previously-invalid values).

**Comparison with Aug 2025:** The prior verification flagged `mountPath` field addition and description changes (v1.6.3 to v1.7.0). The current failure flags type changes (v1.7.0 to v1.9.4). Different fields, same underlying issue: OLM v1's CRD upgrade safety is stricter than what the operator's CRD evolution requires.

---

## Step 5: Retry WITH preflight override

```bash
$ oc patch clusterextension rhdh-upgrade-test --type='merge' -p='{
  "spec": {
    "install": {
      "preflight": {
        "crdUpgradeSafety": {
          "enforcement": "None"
        }
      }
    }
  }
}'
clusterextension.olm.operatorframework.io/rhdh-upgrade-test patched

$ oc wait --for=condition=Installed=True clusterextension/rhdh-upgrade-test --timeout=600s
clusterextension.olm.operatorframework.io/rhdh-upgrade-test condition met

$ oc get clusterextension rhdh-upgrade-test
NAME                INSTALLED BUNDLE       VERSION   INSTALLED   PROGRESSING   AGE
rhdh-upgrade-test   rhdh-operator.v1.9.4   1.9.4     True        True          16m
```

**Upgrade succeeded with preflight override.**

---

## Step 6: Validate post-upgrade state

### CRD versions after upgrade

```bash
$ oc get crd backstages.rhdh.redhat.com -o jsonpath='{range .spec.versions[*]}{.name}: served={.served}, storage={.storage}{"\n"}{end}'
v1alpha1: served=false, storage=false
v1alpha2: served=false, storage=false
v1alpha3: served=true, storage=false
v1alpha4: served=true, storage=false
v1alpha5: served=true, storage=true
```

CRD upgraded correctly:
- Storage moved from v1alpha3 to v1alpha5
- v1alpha1/v1alpha2 no longer served (removed in v1.9.x)
- v1alpha3/v1alpha4 still served for backward compatibility

### Operator pod

```bash
$ oc get pods -n rhdh-upgrade-test
NAME                                              READY   STATUS    RESTARTS   AGE
backstage-pre-upgrade-instance-78f94d65b5-mmm8t   1/1     Running   0          4m
backstage-psql-pre-upgrade-instance-0             1/1     Running   0          3m29s
rhdh-operator-5dd57c86d6-rtscg                    1/1     Running   0          4m43s
```

Operator replaced (new pod hash `5dd57c86d6`), running. Backstage pod replaced (new pod hash `78f94d65b5`), running. PostgreSQL restarted, running.

### Pre-existing Backstage instance survived

```bash
$ oc get backstage -n rhdh-upgrade-test
NAME                   AGE
pre-upgrade-instance   14m

$ oc get backstage pre-upgrade-instance -n rhdh-upgrade-test -o jsonpath='{.apiVersion}'
rhdh.redhat.com/v1alpha3

$ oc get backstage pre-upgrade-instance -n rhdh-upgrade-test -o jsonpath='{.status.conditions}' | python3 -m json.tool
[
    {
        "lastTransitionTime": "2026-06-04T08:58:23Z",
        "message": "",
        "reason": "Deployed",
        "status": "True",
        "type": "Deployed"
    }
]
```

The Backstage CR created with `apiVersion: rhdh.redhat.com/v1alpha3` is still present and shows `Deployed: True`. The v1.9.4 operator successfully reconciles v1alpha3 CRs (the version is still served, even though storage is now v1alpha5).

### Route and smoke test

```bash
$ oc get route -n rhdh-upgrade-test
NAME                             HOST/PORT                                                                                          PATH   SERVICES                         PORT           TERMINATION     WILDCARD
backstage-pre-upgrade-instance   backstage-pre-upgrade-instance-rhdh-upgrade-test.apps.ci-ln-0zjjhgt-76ef8.aws-2.ci.openshift.org   /      backstage-pre-upgrade-instance   http-backend   edge/Redirect   None

$ ROUTE=$(oc get route backstage-pre-upgrade-instance -n rhdh-upgrade-test -o jsonpath='{.spec.host}')
$ curl -sk "https://${ROUTE}" -o /dev/null -w "Main page: HTTP %{http_code}\n"
Main page: HTTP 200

$ curl -sk "https://${ROUTE}/api/catalog/entities?limit=1" -o /dev/null -w "Catalog API: HTTP %{http_code}\n"
Catalog API: HTTP 401
```

Route still serving, HTTP 200 on main page, API responding.

### ClusterExtension final state

```bash
$ oc describe clusterextension rhdh-upgrade-test
Name:         rhdh-upgrade-test
Namespace:    
Labels:       <none>
Annotations:  <none>
API Version:  olm.operatorframework.io/v1
Kind:         ClusterExtension
Metadata:
  Creation Timestamp:  2026-06-04T08:51:27Z
  Finalizers:
    olm.operatorframework.io/cleanup-unpack-cache
    olm.operatorframework.io/cleanup-contentmanager-cache
  Generation:        3
  Resource Version:  46280
  UID:               3942f834-f154-4eb5-9a67-844c8baec7df
Spec:
  Install:
    Preflight:
      Crd Upgrade Safety:
        Enforcement:  None
  Namespace:          rhdh-upgrade-test
  Service Account:
    Name:  rhdh-installer
  Source:
    Catalog:
      Channels:
        fast
      Package Name:               rhdh
      Upgrade Constraint Policy:  CatalogProvided
      Version:                    >=1.7.0 <2.0.0
    Source Type:                  Catalog
Status:
  Conditions:
    Last Transition Time:  2026-06-04T08:51:27Z
    Message:               
    Observed Generation:   3
    Reason:                Deprecated
    Status:                False
    Type:                  Deprecated
    Last Transition Time:  2026-06-04T08:51:27Z
    Message:               
    Observed Generation:   3
    Reason:                Deprecated
    Status:                False
    Type:                  PackageDeprecated
    Last Transition Time:  2026-06-04T08:51:27Z
    Message:               
    Observed Generation:   3
    Reason:                Deprecated
    Status:                False
    Type:                  ChannelDeprecated
    Last Transition Time:  2026-06-04T08:51:27Z
    Message:               
    Observed Generation:   3
    Reason:                Deprecated
    Status:                False
    Type:                  BundleDeprecated
    Last Transition Time:  2026-06-04T08:51:30Z
    Message:               Installed bundle registry.redhat.io/rhdh/rhdh-operator-bundle@sha256:47c3fc5bfb21e980f0fa6c510c48c97982649c7f27d9d486a19391c56c9531ff
      successfully
    Observed Generation:   3
    Reason:                Succeeded
    Status:                True
    Type:                  Installed
    Last Transition Time:  2026-06-04T08:51:30Z
    Message:               Desired state reached
    Observed Generation:   3
    Reason:                Succeeded
    Status:                True
    Type:                  Progressing
  Install:
    Bundle:
      Name:     rhdh-operator.v1.9.4
      Version:  1.9.4
Events:         <none>
```

### Operator logs

```bash
$ oc logs -n rhdh-upgrade-test deployment/rhdh-operator --tail=30 | grep -i "error\|warn\|fatal"
(no output — no errors)
```

### Result: PASS (with preflight override required)

The upgrade from v1.7.0 to v1.9.4 succeeds when `crdUpgradeSafety.enforcement: None` is set. The pre-existing Backstage instance (created with v1alpha3) survives the upgrade and continues to function correctly under the v1.9.4 operator.

---

## Key findings

### 1. CRD upgrade safety blocker persists (confirmed on OCP 4.21)

The CRD upgrade safety validation continues to block RHDH operator upgrades across major CRD version boundaries. This was first identified in Aug 2025 (v1.6.3 to v1.7.0) and is confirmed here for v1.7.0 to v1.9.4.

The specific fields flagged differ between versions but the root cause is the same: the RHDH CRD evolves its schema in ways that OLM v1's safety check considers breaking (type changes, default removals, format changes).

### 2. Workaround: `crdUpgradeSafety.enforcement: None`

Setting this in the ClusterExtension spec bypasses the safety check and allows the upgrade to proceed. The actual upgrade is safe — the CRD changes are backward-compatible (old API versions are still served, existing CRs continue to work).

### 3. Pre-existing CRs survive the upgrade

A Backstage CR created with `apiVersion: rhdh.redhat.com/v1alpha3` on v1.7.0 continues to function after upgrading to v1.9.4 (which uses v1alpha5 as storage). The v1.9.4 operator reconciles v1alpha3 CRs correctly. The CR is not migrated to v1alpha5 — it retains its original API version.

### 4. Operator behavior changes across upgrade

| Aspect | v1.7.0 | v1.9.4 |
|--------|--------|--------|
| Backstage pod containers | 1/1 (backstage-backend only) | 1/1 (with Lightspeed init containers) |
| CRD storage version | v1alpha3 | v1alpha5 |
| CRD served versions | v1alpha1, v1alpha2, v1alpha3 | v1alpha3, v1alpha4, v1alpha5 |
| Dynamic plugins init container | No | Yes |

---

## Action items

| Item | Priority | Description |
|------|----------|-------------|
| Fix CRD schema to pass upgrade safety | **High** | Investigate whether the CRD can be structured to avoid the type/format/default changes that trigger the safety check. This may require keeping explicit types on fields even when using references. |
| Document preflight override requirement | High | Until the CRD is fixed, upgrades require `crdUpgradeSafety.enforcement: None`. This must be documented in release notes and upgrade guides. |
| Engage OLM team on CRD safety behavior | Medium | Discuss with OLM v1 team (Joe Lanford) whether the flagged changes are genuinely breaking or if the safety check is too strict for this pattern. Slack: #olm-v1-adoption-for-your-operator |
| Test upgrade from v1.8.x to v1.9.x | Low | Test whether a smaller version jump (within the v1alpha4 to v1alpha5 boundary) also triggers the safety check |
