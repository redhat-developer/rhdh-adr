# Finding: Makefile `catalog-build` Target Produces SQLite Catalogs Incompatible with OLM v1

**Date:** 2026-06-03  
**Cluster:** OCP 4.21.0-0.nightly-2026-05-28-110248  
**Operator version:** 1.9.0-olmv1-verify-a1b48bd (built from main branch, commit a1b48bd)  
**Feature:** RHDHPLAN-660 — [Operator] OLM v1 adoption  
**Spike:** RHIDP-8656 — [Operator] Spikes for OLM v1 adoption  

---

## Summary

The rhdh-operator Makefile's `catalog-build` target uses `opm index add` which produces a **SQLite-based catalog image**. OLM v1's catalogd on OCP 4.21 **rejects SQLite catalogs** because they are missing the required FBC label (`operators.operatorframework.io.index.configs.v1`). This means any custom catalog image built with the current Makefile cannot be used with OLM v1.

Additionally, when deploying a custom-built operator alongside the default Red Hat catalogs, the ClusterExtension must use `catalogFilter` to target the custom catalog specifically — otherwise OLM v1's resolution picks the highest semver match across all catalogs, which will be the published version from `openshift-redhat-operators`.

---

## Finding 1: SQLite Catalog Image Rejected by OLM v1 catalogd

### What happened

We built all three operator images (operator, bundle, catalog) using the Makefile's standard build pipeline:

```bash
$ make release-build release-push \
    IMAGE_TAG_BASE=quay.io/fndlovu/rhdh-operator \
    VERSION=1.9.0-olmv1-verify-a1b48bd \
    PROFILE=rhdh \
    CONTAINER_TOOL=podman
```

The build succeeded. During the catalog build step, the Makefile ran:

```bash
/home/fndlovu/Documents/olmv1-related/rhdh-operator/bin/opm-v1.23.0 index add --container-tool podman --mode semver --tag quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd --bundles quay.io/fndlovu/rhdh-operator-bundle:1.9.0-olmv1-verify-a1b48bd  --generate -d ./index.Dockerfile
```

This produced a deprecation warning:

```
WARN[0000] DEPRECATION NOTICE:
Sqlite-based catalogs and their related subcommands are deprecated. Support for
them will be removed in a future release. Please migrate your catalog workflows
to the new file-based catalog format.
```

The generated `index.Dockerfile` produced a catalog image with:

```dockerfile
FROM quay.io/operator-framework/opm:latest
LABEL operators.operatorframework.io.index.database.v1=/database/index.db
ADD database/index.db /database/index.db
EXPOSE 50051
ENTRYPOINT ["/bin/opm"]
CMD ["registry", "serve", "--database", "/database/index.db"]
```

Note the label: `operators.operatorframework.io.index.database.v1` — this is the **SQLite format label**.

### The error

We pushed all three images and applied the OLM v1 manifests:

```bash
$ oc apply -f rhdh-olmv1-verification.yaml
namespace/rhdh-system created
serviceaccount/rhdh-installer created
clusterrolebinding.rbac.authorization.k8s.io/rhdh-installer-binding created
clustercatalog.olm.operatorframework.io/rhdh-custom-catalog created
clusterextension.olm.operatorframework.io/rhdh created
```

The ClusterExtension never installed. It hung waiting:

```bash
$ oc wait --for=condition=Installed=True clusterextension/rhdh --timeout=600s
# (timed out / cancelled)
```

We checked the ClusterExtension status:

```bash
$ oc get clusterextension rhdh -o yaml | grep message
    message: 'error walking catalogs: error getting package "rhdh" from catalog
      "rhdh-custom-catalog": catalog "rhdh-custom-catalog" is not being served'
```

We then checked the ClusterCatalog to find out why it wasn't serving:

```bash
$ oc describe clustercatalog rhdh-custom-catalog
Name:         rhdh-custom-catalog
Namespace:    
Labels:       olm.operatorframework.io/metadata.name=rhdh-custom-catalog
Annotations:  <none>
API Version:  olm.operatorframework.io/v1
Kind:         ClusterCatalog
Metadata:
  Creation Timestamp:  2026-06-03T15:09:16Z
  Finalizers:
    olm.operatorframework.io/delete-server-cache
  Generation:        1
  Resource Version:  60542
  UID:               9e247c7c-73a2-4946-bd40-f4a56433f09d
Spec:
  Availability Mode:  Available
  Priority:           200
  Source:
    Image:
      Ref:  quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd
    Type:   Image
Status:
  Conditions:
    Last Transition Time:  2026-06-03T15:09:17Z
    Message:               source catalog content: error applying image: catalog image is missing the required label "operators.operatorframework.io.index.configs.v1"
    Observed Generation:   1
    Reason:                Retrying
    Status:                True
    Type:                  Progressing
Events:                    <none>
```

**Root cause:** OLM v1's catalogd requires the FBC label `operators.operatorframework.io.index.configs.v1` on catalog images. The SQLite catalog built by `opm index add` has the old label `operators.operatorframework.io.index.database.v1` instead. catalogd does not support SQLite catalogs.

### The fix: Build an FBC (File-Based Catalog) image manually

Instead of using `opm index add` (SQLite), we built a File-Based Catalog using `opm init` and `opm render`:

```bash
$ cd /home/fndlovu/Documents/olmv1-related/rhdh-operator

# Create FBC directory
$ mkdir -p catalog-fbc

# Initialize the package and render the bundle into FBC format
$ ./bin/opm-v1.23.0 init rhdh --default-channel=fast --output yaml > catalog-fbc/catalog.yaml
$ ./bin/opm-v1.23.0 render quay.io/fndlovu/rhdh-operator-bundle:1.9.0-olmv1-verify-a1b48bd --output yaml >> catalog-fbc/catalog.yaml

# Add the channel entry
$ cat >> catalog-fbc/catalog.yaml << 'EOF'
---
schema: olm.channel
package: rhdh
name: fast
entries:
- name: rhdh-operator.v1.9.0-olmv1-verify-a1b48bd
EOF
```

We created a simple Dockerfile with the correct FBC label:

```dockerfile
FROM scratch
ADD catalog.yaml /configs/catalog.yaml
LABEL operators.operatorframework.io.index.configs.v1=/configs/
```

Built and pushed the new FBC catalog image (overwriting the old SQLite one):

```bash
$ podman build -f catalog-fbc/Dockerfile -t quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd catalog-fbc/
STEP 1/3: FROM scratch
STEP 2/3: ADD catalog.yaml /configs/catalog.yaml
--> 14b5cec095f0
STEP 3/3: LABEL operators.operatorframework.io.index.configs.v1=/configs/
COMMIT quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd
--> a838b4f64bea
Successfully tagged quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd
a838b4f64bea5d77af638af36ced62a2244836844d979ee41883f5576b54c776

$ podman push quay.io/fndlovu/rhdh-operator-catalog:1.9.0-olmv1-verify-a1b48bd
Getting image source signatures
Copying blob sha256:36b9088e2df8c209fd570b5a074ff8d956f2fadb45b9cf9aefdad67319e90cc3
Copying config sha256:a838b4f64bea5d77af638af36ced62a2244836844d979ee41883f5576b54c776
Writing manifest to image destination
```

Deleted and recreated the ClusterCatalog:

```bash
$ oc delete clustercatalog rhdh-custom-catalog
clustercatalog.olm.operatorframework.io "rhdh-custom-catalog" deleted

$ cat <<'EOF' | oc apply -f -
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
EOF
clustercatalog.olm.operatorframework.io/rhdh-custom-catalog created
```

### Verification: Catalog now serving

```bash
$ oc get clustercatalog rhdh-custom-catalog
NAME                  LASTUNPACKED   SERVING   AGE
rhdh-custom-catalog   13m            True      13m
```

The catalog is now `Serving: True`.

### Impact on the codebase

The Makefile target `catalog-build` (line ~339) needs to be updated to produce FBC catalogs instead of SQLite. The current target:

```makefile
$(OPM) index add --container-tool $(CONTAINER_TOOL) --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT) --generate -d ./index.Dockerfile
$(CONTAINER_TOOL) build --platform linux/amd64 -f index.Dockerfile -t $(CATALOG_IMG) ...
```

Should be replaced with an FBC workflow using `opm init`, `opm render`, and a Dockerfile with the `operators.operatorframework.io.index.configs.v1` label.

---

## Finding 2: ClusterExtension Resolves from Wrong Catalog Without `catalogFilter`

### What happened

After fixing the catalog (Finding 1), the ClusterExtension installed — but it installed the wrong version. It picked up `v1.9.4` from the default `openshift-redhat-operators` catalog instead of our custom build `v1.9.0-olmv1-verify-a1b48bd` from `rhdh-custom-catalog`.

```bash
$ oc get clusterextension rhdh
NAME   INSTALLED BUNDLE       VERSION   INSTALLED   PROGRESSING   AGE
rhdh   rhdh-operator.v1.9.4   1.9.4     True        True          13m
```

Our ClusterExtension spec had:

```yaml
spec:
  source:
    sourceType: Catalog
    catalog:
      packageName: rhdh
      version: ">=1.9.0 <2.0.0"
      channels: [fast]
```

Both the default `openshift-redhat-operators` catalog and our `rhdh-custom-catalog` contain a package named `rhdh`. OLM v1 resolves across **all** catalogs and picks the highest semver match. Since `1.9.4 > 1.9.0-olmv1-verify-a1b48bd`, the published version won.

### Attempted fix 1: Pin the exact version (failed)

We tried patching to the exact version string:

```bash
$ oc patch clusterextension rhdh --type='merge' -p='{
  "spec": {
    "source": {
      "catalog": {
        "packageName": "rhdh",
        "version": "1.9.0-olmv1-verify-a1b48bd",
        "channels": ["fast"]
      }
    }
  }
}'
clusterextension.olm.operatorframework.io/rhdh patched
```

This failed because OLM v1 can't downgrade from an already-installed higher version:

```bash
$ oc get clusterextension rhdh
NAME   INSTALLED BUNDLE       VERSION   INSTALLED   PROGRESSING   AGE
rhdh   rhdh-operator.v1.9.4   1.9.4     True        True          14m

$ oc describe clusterextension rhdh | grep -A3 "Message.*error"
    Message:               error upgrading from currently installed version "1.9.4": no bundles found for package "rhdh" matching version "1.9.0-olmv1-verify-a1b48bd" in channels [fast]
    Observed Generation:   2
    Reason:                Retrying
    Status:                True
    Type:                  Progressing
```

### The fix: Delete and recreate with `catalogFilter`

We deleted the ClusterExtension and recreated it with `catalogFilter` to restrict resolution to our custom catalog only:

```bash
$ oc delete clusterextension rhdh
clusterextension.olm.operatorframework.io "rhdh" deleted

$ cat <<'EOF' | oc apply -f -
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
clusterextension.olm.operatorframework.io/rhdh created
```

### Verification: Custom build installed correctly

```bash
$ oc get clusterextension rhdh
NAME   INSTALLED BUNDLE                            VERSION                      INSTALLED   PROGRESSING   AGE
rhdh   rhdh-operator.v1.9.0-olmv1-verify-a1b48bd   1.9.0-olmv1-verify-a1b48bd   True        True          10m

$ oc describe clusterextension rhdh
Name:         rhdh
Namespace:    
Labels:       <none>
Annotations:  <none>
API Version:  olm.operatorframework.io/v1
Kind:         ClusterExtension
Metadata:
  Creation Timestamp:  2026-06-03T15:24:11Z
  Finalizers:
    olm.operatorframework.io/cleanup-unpack-cache
    olm.operatorframework.io/cleanup-contentmanager-cache
  Generation:        1
  Resource Version:  65685
  UID:               90c2877e-96da-4c06-a1f1-1e5fa50a0af1
Spec:
  Namespace:  rhdh-system
  Service Account:
    Name:  rhdh-installer
  Source:
    Catalog:
      Package Name:               rhdh
      Upgrade Constraint Policy:  CatalogProvided
    Source Type:                  Catalog
Status:
  Conditions:
    Last Transition Time:  2026-06-03T15:24:11Z
    Message:               
    Observed Generation:   1
    Reason:                Deprecated
    Status:                False
    Type:                  Deprecated
    Last Transition Time:  2026-06-03T15:24:11Z
    Message:               
    Observed Generation:   1
    Reason:                Deprecated
    Status:                False
    Type:                  PackageDeprecated
    Last Transition Time:  2026-06-03T15:24:11Z
    Message:               
    Observed Generation:   1
    Reason:                Deprecated
    Status:                False
    Type:                  ChannelDeprecated
    Last Transition Time:  2026-06-03T15:24:11Z
    Message:               
    Observed Generation:   1
    Reason:                Deprecated
    Status:                False
    Type:                  BundleDeprecated
    Last Transition Time:  2026-06-03T15:24:13Z
    Message:               Installed bundle quay.io/fndlovu/rhdh-operator-bundle:1.9.0-olmv1-verify-a1b48bd successfully
    Observed Generation:   1
    Reason:                Succeeded
    Status:                True
    Type:                  Installed
    Last Transition Time:  2026-06-03T15:24:13Z
    Message:               Desired state reached
    Observed Generation:   1
    Reason:                Succeeded
    Status:                True
    Type:                  Progressing
  Install:
    Bundle:
      Name:     rhdh-operator.v1.9.0-olmv1-verify-a1b48bd
      Version:  1.9.0-olmv1-verify-a1b48bd
Events:         <none>
```

Operator pod running:

```bash
$ oc get pods -n rhdh-system
NAME                             READY   STATUS    RESTARTS   AGE
rhdh-operator-86745788c8-lbg5c   1/1     Running   0          10m

$ oc get crd backstages.rhdh.redhat.com
NAME                         CREATED AT
backstages.rhdh.redhat.com   2026-06-03T15:24:13Z
```

### Key takeaway

When deploying a custom-built operator to a cluster that also has the default Red Hat catalogs (which contain the published `rhdh` package), you **must** use `catalogFilter` on the ClusterExtension spec to restrict resolution to your custom catalog. Otherwise OLM v1 resolves across all catalogs and picks the highest semver match, which will be the published version.

This is different from OLM v0 where you specify the `source` and `sourceNamespace` on the Subscription to point at a specific CatalogSource.

---

## Verification: Runtime validation after fixes applied

After resolving both findings above, we validated that the custom-built operator functions correctly end-to-end under OLM v1.

### Operator installation confirmed

```bash
$ oc get clusterextension rhdh
NAME   INSTALLED BUNDLE                            VERSION                      INSTALLED   PROGRESSING   AGE
rhdh   rhdh-operator.v1.9.0-olmv1-verify-a1b48bd   1.9.0-olmv1-verify-a1b48bd   True        True          10m

$ oc get clustercatalog rhdh-custom-catalog
NAME                  LASTUNPACKED   SERVING   AGE
rhdh-custom-catalog   13m            True      13m

$ oc get pods -n rhdh-system
NAME                             READY   STATUS    RESTARTS   AGE
rhdh-operator-86745788c8-lbg5c   1/1     Running   0          10m

$ oc get crd backstages.rhdh.redhat.com
NAME                         CREATED AT
backstages.rhdh.redhat.com   2026-06-03T15:24:13Z
```

### Backstage CR creation

Created a Backstage instance to validate the operator reconciles correctly under OLM v1:

```bash
$ cat <<'EOF' | oc apply -f -
apiVersion: rhdh.redhat.com/v1alpha5
kind: Backstage
metadata:
  name: verification-test
  namespace: rhdh-system
spec:
  application:
    replicas: 1
  database:
    enableLocalDb: true
EOF
backstage.rhdh.redhat.com/verification-test created

$ oc wait --for=condition=Available deployment/backstage-verification-test -n rhdh-system --timeout=600s
deployment.apps/backstage-verification-test condition met
```

### All pods running

```bash
$ oc get pods -n rhdh-system
NAME                                           READY   STATUS    RESTARTS   AGE
backstage-psql-verification-test-0             1/1     Running   0          4m12s
backstage-verification-test-7b8f6577dc-k8vlq   2/2     Running   0          4m12s
rhdh-operator-86745788c8-lbg5c                 1/1     Running   0          19m
```

The Backstage pod has 2/2 containers (backstage-backend + lightspeed sidecar). PostgreSQL StatefulSet is running.

### Route created and accessible

```bash
$ oc get route -n rhdh-system
NAME                          HOST/PORT                                                                                 PATH   SERVICES                      PORT           TERMINATION     WILDCARD
backstage-verification-test   backstage-verification-test-rhdh-system.apps.ci-ln-nlyfdi2-76ef8.aws-2.ci.openshift.org   /      backstage-verification-test   http-backend   edge/Redirect   None
```

### Smoke test — HTTP responses

```bash
$ ROUTE=$(oc get route backstage-verification-test -n rhdh-system -o jsonpath='{.spec.host}')
$ echo "Route: ${ROUTE}"
Route: backstage-verification-test-rhdh-system.apps.ci-ln-nlyfdi2-76ef8.aws-2.ci.openshift.org

$ curl -sk "https://${ROUTE}" -o /dev/null -w "HTTP %{http_code}\n"
HTTP 200

$ curl -sk "https://${ROUTE}/api/catalog/entities?limit=1" -o /dev/null -w "Catalog API: HTTP %{http_code}\n"
Catalog API: HTTP 401
```

- Main page: `HTTP 200` — UI is served
- Catalog API: `HTTP 401` — API is up, returns unauthorized as expected (requires auth)

### Result: PASS

The custom-built RHDH operator (v1.9.0-olmv1-verify-a1b48bd, main branch commit a1b48bd) installs and runs correctly under OLM v1 on OCP 4.21. The operator reconciles Backstage CRs, creates deployments, StatefulSets, services, and routes as expected. No functional differences observed compared to OLM v0 deployment.

---

## Action items

| Item | Priority | Description |
|------|----------|-------------|
| Update `catalog-build` Makefile target | High | Replace `opm index add` (SQLite) with FBC workflow (`opm init` + `opm render` + FBC Dockerfile with `index.configs.v1` label) |
| Add `catalog-build-fbc` Makefile target | Medium | Alternative: add a new target alongside the existing one for backward compatibility |
| Update verification guide | Medium | Document `catalogFilter` usage when deploying custom builds alongside default catalogs |
| Update `deploy-olm` targets | Medium | Future OLM v1 deploy targets must include `catalogFilter` when using custom catalogs |
| Update `install-rhdh-catalog-source.sh` | Low (not urgent) | When script is updated for OLM v1, use FBC catalog format and `catalogFilter` |
