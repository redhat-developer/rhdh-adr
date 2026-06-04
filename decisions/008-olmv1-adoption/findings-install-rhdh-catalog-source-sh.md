# Finding: `install-rhdh-catalog-source.sh` Bypasses OLM v1 Entirely

**Date:** 2026-06-04  
**Cluster:** OCP 4.21.0-0.nightly-2026-06-03-102204  
**Script:** `.rhdh/scripts/install-rhdh-catalog-source.sh`  
**Invocation:** `bash .rhdh/scripts/install-rhdh-catalog-source.sh --latest --install-operator rhdh`  
**Feature:** RHDHPLAN-660 — [Operator] OLM v1 adoption  
**Spike:** RHIDP-8656 — [Operator] Spikes for OLM v1 adoption  

---

## Summary

The script completed successfully on an OCP 4.21 cluster that has **both OLM v0 and OLM v1 installed**. It installed RHDH operator v1.10.0 entirely through the OLM v0 path (CatalogSource + Subscription + OperatorGroup). It never creates or interacts with any OLM v1 resources (ClusterCatalog, ClusterExtension). This means the script is non-functional for OLM v1-only clusters and does not exercise OLM v1 even when it is available.

---

## Cluster state before run

Both OLM v0 and v1 CRDs were present:

```
$ oc get crd clusterextensions.olm.operatorframework.io
NAME                                         CREATED AT
clusterextensions.olm.operatorframework.io   2026-06-04T08:06:27Z

$ oc get crd catalogsources.operators.coreos.com
NAME                                  CREATED AT
catalogsources.operators.coreos.com   2026-06-04T08:03:41Z

$ oc get crd clustercatalogs.olm.operatorframework.io
NAME                                       CREATED AT
clustercatalogs.olm.operatorframework.io   2026-06-04T08:06:27Z
```

A pre-existing OLM v1 ClusterExtension was already deployed from prior upgrade testing:

```
$ oc get clusterextension
NAME                INSTALLED BUNDLE       VERSION   INSTALLED   PROGRESSING   AGE
rhdh-upgrade-test   rhdh-operator.v1.9.4   1.9.4     True        True          49m
```

Default OLM v0 CatalogSources and OLM v1 ClusterCatalogs were both present. No prior Subscription or OperatorGroup existed in `rhdh-operator` namespace.

---

## What the script did

### Phase 1: IIB rendering and image rebuild (~8 minutes)

The script detected OpenShift, resolved `quay.io/rhdh/iib:latest-v4.21-x86_64` as the IIB image, and ran the `ocp_install` function:

1. Exposed the internal cluster registry (`image-registry.openshift-image-registry.svc:5000`)
2. Created registry auth secrets in `openshift-marketplace` namespace
3. Created `rhdh-operator` and `rhdh` namespaces
4. Rendered the IIB with `opm render` — produced render.yaml with 43 bundles
5. Processed all 43 bundles in parallel (max 10): pulled via skopeo, unpacked with umoci, replaced internal registry refs with quay.io equivalents, repacked, pushed to internal registry
6. Applied 43 image ref replacements to render.yaml
7. Built the updated IIB image in-cluster via `oc new-build` / `oc start-build`
8. Tagged the image as `rhdh/iib:latest-v4.21-x86_64`

### Phase 2: OLM v0 resource creation

The script then created **exclusively OLM v0 resources**:

```
catalogsource.operators.coreos.com/rhdh-fast created
operatorgroup.operators.coreos.com/rhdh-operator-group created
subscription.operators.coreos.com/rhdh created
```

OLM v0 resolved the Subscription and created an InstallPlan:

```
$ oc get csv -n rhdh-operator
NAME                     DISPLAY                          VERSION   PHASE
rhdh-operator.v1.10.0    Red Hat Developer Hub Operator   1.10.0    Succeeded

$ oc get installplan -n rhdh-operator
NAME              CSV                     APPROVAL    APPROVED
install-4t2tw     rhdh-operator.v1.10.0   Automatic   true
```

### Phase 3: Output

The script printed the OCP console URL and a sample `Backstage` CR to deploy.

---

## Observations

### 1. Script has zero OLM v1 awareness

The script does not check for or interact with any OLM v1 CRDs or resources. Every code path leads to OLM v0 resource creation:

| Script line | What it does | OLM version |
|-------------|--------------|-------------|
| 651 | Checks for `catalogsources.operators.coreos.com` CRD | v0 only |
| 825-840 | Creates `CatalogSource` in `openshift-marketplace` | v0 only |
| 842-848 | Creates `OperatorGroup` in `rhdh-operator` | v0 only |
| 857-869 | Creates `Subscription` in `rhdh-operator` | v0 only |
| 752-767 | Pre-checks for existing OperatorGroups | v0 only |

### 2. On OLM v1-only clusters, the script would succeed but the operator would not install

On OCP 4.21, both OLM v0 and v1 are present, so the script works via the v0 path. However:

- When OLM v0 is eventually removed (expected in a future OCP release), the `CatalogSource` CRD will not exist and the script will fail at line 651 (K8s path) or at line 825 (OCP path, `oc apply` of CatalogSource would fail with unknown resource)
- Even before removal, if a cluster admin disables OLM v0, the same failure occurs

### 3. The IIB rendering + rebuild phase is OLM-version-agnostic

The `ocp_install` function (lines 275-340) renders the IIB, rebuilds bundles with corrected registry refs, and pushes to the internal registry. This work is independent of whether the catalog is consumed by OLM v0 or v1. The resulting image in the internal registry could be referenced by either a CatalogSource or a ClusterCatalog.

### 4. K8s path has a harder failure point

For non-OpenShift K8s clusters, line 651 explicitly checks for the `catalogsources.operators.coreos.com` CRD and exits with "OLM not installed" if it's missing. A K8s cluster running only OLM v1 (via operator-controller) would not have this CRD, so the script would refuse to run entirely.

### 5. No conflict with pre-existing OLM v1 resources

The script's OLM v0 install coexisted with the pre-existing `rhdh-upgrade-test` ClusterExtension without issues. Both the OLM v0 Subscription and the OLM v1 ClusterExtension resolved and installed successfully — though this means two separate installations of the operator existed simultaneously (v1.10.0 via v0, v1.9.4 via v1).

---

## What would need to change

These are observations only — no implementation in this spike.

### Option A: Dual-path with detection

Add OLM v1 detection and a parallel code path:

- Detect OLM v1: check if `clusterextensions.olm.operatorframework.io` CRD exists
- If OLM v1 is available, create ClusterCatalog + ClusterExtension instead of CatalogSource + Subscription + OperatorGroup
- Keep OLM v0 path as fallback for older clusters
- Key differences in OLM v1 path:
  - No `openshift-marketplace` namespace — ClusterCatalog is cluster-scoped
  - No Subscription — ClusterExtension replaces it
  - No OperatorGroup — not needed
  - `catalogFilter` needed when custom catalogs coexist with default Red Hat catalogs
  - ServiceAccount with cluster-admin ClusterRoleBinding needed for ClusterExtension

### Option B: Prefer OLM v1 when both are available

Same as Option A, but when both OLM v0 and v1 are present, prefer the v1 path. This tests the v1 flow on clusters where both exist (like OCP 4.18-4.21).

### Option C: CLI flag to choose OLM version

Add `--olm-version v0|v1|auto` flag. `auto` would detect and prefer v1 when available.

### Items specific to OLM v1 path

If an OLM v1 path is added, these resources would need to be created:

```yaml
# Instead of CatalogSource
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: rhdh-fast
spec:
  source:
    type: Image
    image:
      ref: <newIIBImage>
      pullSecret: internal-reg-auth-for-rhdh

# Instead of Subscription + OperatorGroup
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: rhdh
spec:
  namespace: rhdh-operator
  serviceAccount:
    name: rhdh-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: rhdh
      channels: [fast]
      catalogFilter: "metadata.name=rhdh-fast"
```

Plus a ServiceAccount + ClusterRoleBinding:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhdh-installer
  namespace: rhdh-operator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhdh-installer-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: rhdh-installer
  namespace: rhdh-operator
```

---

## Full log

The complete script output (567 lines) is saved at:
`install-rhdh-catalog-source-run1.log`
