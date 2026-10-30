# ADR-009: Disconnected Install: Dual-Layer Mirror Strategy (Operator)

## Executive Summary / TL;DR

RHDH Operator needs two complementary mechanisms for air-gapped (disconnected) installs, each solving a different part of the problem:

1. **`spec.relatedImages` + `RELATED_IMAGE_*` env vars** — Declare all container images the operator may need in the CSV (ClusterServiceVersion). This is the standard pattern every Red Hat operator follows. It enables `oc-mirror` to discover and copy images automatically, satisfies [Conforma](https://redhat.atlassian.net/browse/RHDHSUPP-417) downstream pipeline validation, and complies with [OpenShift disconnected operator requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index#olm-restricted-networks).

2. **ConfigMap-based runtime mirror resolution** — Extend the operator's existing `plugin-registry-mirror` ConfigMap (already used for dynamic plugin packages) to also rewrite container image references at reconciliation time. This gives users a dynamic, platform-agnostic way to point the operator at their mirror registry — including on platforms where IDMS/ITMS are unavailable (Rosa HCP, vanilla Kubernetes).

**Why both?** They solve different problems. `spec.relatedImages` tells tooling *what* images exist. ConfigMap resolution tells the operator *where* to pull them from at runtime. Dropping either one creates gaps: without `spec.relatedImages`, `oc-mirror` and Conforma break; without ConfigMap resolution, users on Rosa HCP or vanilla Kubernetes have no supported runtime path.

**Current gap**: The operator's CSV only lists 2 images ([postgresql, backstage](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L498-L502)). Lightspeed/Intelligent Assistant images (lightspeed-core sidecar, OKP, RAG init container) are hidden inside flavour ConfigMaps, undiscoverable by standard tooling. The current [air-gap documentation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant) acknowledges this:

> "The `prepare-restricted-environment.sh` script does **not automatically parse Developer Lightspeed for RHDH images from the bundle manifest**, so mirror these images manually before running the script."

---

## Glossary: Key Terms Explained

Before diving in, here is what the technical terms in this ADR mean:

| Term | What it means |
|------|---------------|
| **CSV** (ClusterServiceVersion) | A YAML file inside an operator's bundle that describes the operator to OLM — what it installs, what permissions it needs, and what container images it uses. Think of it as the operator's "manifest" or "bill of materials." |
| **`spec.relatedImages`** | A section inside the CSV that lists every container image the operator might need. Disconnected tooling (`oc-mirror`) reads this list to know what to copy to the customer's mirror registry. |
| **`RELATED_IMAGE_*` env vars** | Environment variables set on the operator's own pod (e.g., `RELATED_IMAGE_backstage=registry.example.com/rhdh@sha256:...`). The operator code reads these at startup and uses them to decide which image to put into the Backstage Deployment it creates. When OLM installs the operator on a disconnected cluster, it automatically rewrites these env vars to point at the mirror registry (via IDMS/ITMS). |
| **IDMS / ITMS** | ImageDigestMirrorSet / ImageTagMirrorSet. OpenShift cluster-level resources that tell the container runtime (CRI-O) "when you see a pull for `registry.redhat.io/foo`, actually pull from `mirror.company.com/foo` instead." These work transparently — pods don't need to know about the mirror. But they are OpenShift-only and do not work on Rosa HCP or vanilla Kubernetes. |
| **`oc-mirror`** | Red Hat's official CLI tool for copying operator images to a disconnected mirror registry. It reads `spec.relatedImages` from the CSV to know which images to copy. If an image isn't listed there, `oc-mirror` won't copy it. |
| **Conforma** | A validation framework in Red Hat's downstream build pipelines. It checks, among other things, that all images in `spec.relatedImages` come from trusted registries. If we skip `spec.relatedImages`, Conforma checks can't validate our images. |
| **ConfigMap mirror resolution** | A mechanism already built into the RHDH operator for dynamic plugins. Users create a Kubernetes ConfigMap with "source → mirror" mappings. The operator reads this ConfigMap and rewrites image URLs before creating Kubernetes objects. Pods see already-resolved mirror paths. |
| **Flavour** | An RHDH operator concept. A flavour is a bundle of configuration (ConfigMaps) that enables a feature set — e.g., `intelligent-assistant` adds Lightspeed AI capabilities, `orchestrator` adds workflow support. Flavours can define additional container images and plugin packages. |
| **Rosa HCP** | Red Hat OpenShift Service on AWS with Hosted Control Planes. A managed OpenShift variant where IDMS/ITMS are not available because the control plane is managed by Red Hat, not the customer. |
| **OCI package** | A container-image-shaped artifact that contains a dynamic plugin (JavaScript code, not a running container). Stored in a container registry but extracted and loaded by the plugin installer, not run as a pod. |

---

## Context

### The Air-Gap Problem in Plain Terms

When an organisation runs RHDH on a network with no internet access (a "disconnected" or "air-gapped" environment), every container image the operator needs must be pre-copied to an internal mirror registry. This involves three steps:

1. **Discover** — Figure out which images are needed
2. **Mirror** — Copy those images from the public registry to the internal registry
3. **Resolve** — Tell the running operator and its pods where to pull from (the mirror, not the internet)

Today, RHDH has gaps in all three steps for Lightspeed / Intelligent Assistant images.

### What Works Today

**Core images (2 of them)** — `backstage` and `postgresql` — follow the standard OpenShift pattern end-to-end:

- ✅ Listed in CSV [`spec.relatedImages`](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L498-L502) (discoverable by `oc-mirror`)
- ✅ Declared as [`RELATED_IMAGE_*` env vars](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L311-L316) on the operator deployment (resolved by OLM + IDMS/ITMS at runtime)
- ✅ Operator code reads these env vars and substitutes them into the Backstage Deployment ([`deployment.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L112-L114)) and PostgreSQL StatefulSet ([`db-statefulset.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/db-statefulset.go#L17))

**Dynamic plugin OCI packages** — already have ConfigMap-based mirror resolution:

- ✅ Users create a [`plugin-registry-mirror` ConfigMap](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins-mirror.go) with source → mirror mappings
- ✅ Operator reads it during [reconciliation preprocessing](https://github.com/redhat-developer/rhdh-operator/blob/main/internal/controller/spec_preprocessor.go#L157) and rewrites plugin package URLs in [dynamic-plugins.go](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins.go#L176)

### What Does Not Work Today

**Lightspeed / Intelligent Assistant images (3 of them)** are invisible to standard tooling:

| Image | Size | Source | Problem |
|-------|------|--------|---------|
| `lightspeed-core` sidecar (`quay.io/lightspeed-core/lightspeed-stack:0.7.0`) | ~1 GB | [Flavour ConfigMap](https://github.com/redhat-developer/rhdh-operator/tree/main/config/profile/rhdh/flavour-lightspeed) | Not in `spec.relatedImages`, not discoverable by `oc-mirror` |
| OKP (`registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:1.2.12`) | 10+ GB | [plugin-deps ConfigMap](https://github.com/redhat-developer/rhdh-operator/blob/main/config/profile/rhdh/plugin-deps/okp.yaml) | Not in `spec.relatedImages`, optional feature, huge image |
| RAG init container (`registry.access.redhat.com/rhdh/rhdh-lightspeed-rag-content-init-rhel9@sha256:...`) | ~200 MB | Flavour ConfigMap | Not in `spec.relatedImages` |

These images exist only inside bundle ConfigMaps. Users must manually extract them from the bundle to discover what to mirror — and even after mirroring, there is no runtime resolution mechanism for them (IDMS/ITMS handles the 2 core images via `RELATED_IMAGE_*`, but Lightspeed images bypass that path entirely).

### Why This Matters to Customers

From [RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417): customers managing multiple disconnected OpenShift clusters use `oc-mirror` as their standardised mirroring workflow for all Red Hat operators. They expect RHDH to work the same way. When Lightspeed images are missing from `spec.relatedImages`, their established workflow breaks — RHDH becomes the exception they have to handle manually.

### What Other Red Hat Operators Do

The `spec.relatedImages` + `RELATED_IMAGE_*` pattern is the standard across Red Hat's operator portfolio. Examples:

- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml#L590-L593)
- [OADP Operator](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml#L1484-L1519)
- [Quay Operator](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml#L153-L170)
- [DevWorkspace Operator](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml#L410-L445)
- [Sandboxed Containers Operator](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml#L420-L437)

RHDH should follow this established pattern.

---

## Decision

### Adopt a dual-layer strategy: declare images in the CSV AND resolve them dynamically via ConfigMap

Both layers are required. They are complementary, not competing:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LAYER 1: DECLARATION                             │
│           spec.relatedImages + RELATED_IMAGE_* env vars             │
│                                                                     │
│  Purpose: Tell tooling WHAT images this operator needs              │
│  Used by: oc-mirror, Conforma, OLM, auditors                       │
│  Scope:   All container images the operator may create pods for     │
│  Where:   CSV in the operator bundle                                │
│  When:    Build time (bundle generation via `make bundle`)          │
└─────────────────────────────────────────────────────────────────────┘
                              +
┌─────────────────────────────────────────────────────────────────────┐
│                    LAYER 2: RUNTIME RESOLUTION                      │
│              ConfigMap-based mirror resolution                      │
│                                                                     │
│  Purpose: Tell the operator WHERE to pull images from               │
│  Used by: Operator reconciliation loop                              │
│  Scope:   Container images + plugin OCI packages                    │
│  Where:   User-created ConfigMap in the operator namespace          │
│  When:    Runtime (every Backstage CR reconciliation)               │
└─────────────────────────────────────────────────────────────────────┘
```

#### Layer 1: `spec.relatedImages` + `RELATED_IMAGE_*` (Declaration)

**What**: Add Lightspeed images to the CSV's `spec.relatedImages` list and corresponding `RELATED_IMAGE_*` environment variables on the operator deployment. This follows the exact same pattern already used for `backstage` and `postgresql`.

**Images to add**:

```yaml
# In CSV spec.relatedImages (digest-pinned in downstream builds):
- image: registry.access.redhat.com/rhdh/rhdh-lightspeed-rag-content-init-rhel9@sha256:...
  name: lightspeed-rag-init
- image: registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9@sha256:...
  name: lightspeed-core
- image: registry.redhat.io/offline-knowledge-portal/rhokp-rhel9@sha256:...
  name: okp
```

```yaml
# Corresponding env vars on the operator deployment in the CSV:
- name: RELATED_IMAGE_lightspeed_rag_init
  value: registry.access.redhat.com/rhdh/rhdh-lightspeed-rag-content-init-rhel9@sha256:...
- name: RELATED_IMAGE_lightspeed_core
  value: registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9@sha256:...
- name: RELATED_IMAGE_okp
  value: registry.redhat.io/offline-knowledge-portal/rhokp-rhel9@sha256:...
```

**Why this matters**:
- `oc-mirror` reads `spec.relatedImages` to discover images. Without these entries, it won't copy Lightspeed images to the mirror. ([RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417))
- Conforma validation in downstream build pipelines checks that all images in `spec.relatedImages` come from trusted registries. Skipping this means Conforma can't validate Lightspeed images.
- `make bundle` automatically generates `spec.relatedImages` from `RELATED_IMAGE_*` env vars — this is not manual maintenance.

**OKP image size (10+ GB)**: OKP is optional and large. Listing it in `spec.relatedImages` means `oc-mirror` will copy it even if the user doesn't enable the intelligent-assistant flavour. Two mitigations:

1. **Now**: Document clearly that OKP is optional and can be excluded from `ImageSetConfiguration` if not using the intelligent-assistant flavour with offline knowledge portal.
2. **Future**: [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) — the OCP team is planning to add mandatory vs optional classification for `spec.relatedImages`. Once available, we mark OKP as optional so `oc-mirror` skips it by default.

**Operator code changes**: For each new image, add a `RELATED_IMAGE_*` env var read in the corresponding model code, following the existing pattern in [`deployment.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L31):

```go
const LightspeedCoreImageEnvVar = "RELATED_IMAGE_lightspeed_core"

// In the flavour's addToModel() or equivalent:
if os.Getenv(LightspeedCoreImageEnvVar) != "" {
    container.Image = os.Getenv(LightspeedCoreImageEnvVar)
}
```

**User override (OpenShift)**: Users can override specific images via [Subscription `spec.config.env`](https://github.com/redhat-developer/rhdh-operator/blob/main/config/samples/catalog-subscription-template.yaml) (OLM v0) or equivalent [ClusterExtension](https://github.com/redhat-developer/rhdh-operator/blob/main/config/samples/catalog-cluster-extension-template.yaml) configuration (OLM v1):

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhdh-operator
  namespace: rhdh-operator
spec:
  channel: stable
  name: rhdh-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
    env:
      - name: RELATED_IMAGE_lightspeed_core
        value: mirror.company.com/lightspeed-core/lightspeed-stack-rhel9@sha256:...
```

#### Layer 2: ConfigMap Mirror Resolution (Runtime)

**What**: Extend the operator's existing [`plugin-registry-mirror` ConfigMap](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins-mirror.go) mechanism to also rewrite container image references (not just plugin OCI packages) during reconciliation.

**How it works today (plugins only)**:
1. User creates a ConfigMap named `plugin-registry-mirror` in the operator namespace with source → mirror mappings
2. ConfigMap is [mounted into the operator pod](https://github.com/redhat-developer/rhdh-operator/blob/main/config/manager/deployment.yaml#L103-L122) at `/plugins-mirror/mirrors.yaml`
3. Operator [loads the mappings](https://github.com/redhat-developer/rhdh-operator/blob/main/internal/controller/spec_preprocessor.go#L157) during reconciliation preprocessing
4. Mappings are [applied to plugin OCI package URLs](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins.go#L176) — rewriting `registry.access.redhat.com/rhdh/...` → `mirror.company.com/rhdh/...`

**What changes**: Apply the same rewriting to container image fields in Deployments, StatefulSets, and plugin-deps during `addToModel()`. The mirror logic in [`dynamic-plugins-mirror.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins-mirror.go) gets extended to handle plain image references (without the `oci://` prefix used for plugins).

**ConfigMap format** (inspired by IDMS/ITMS but not directly copy-pasteable from an IDMS resource — the structure is similar for familiarity but it is the operator's own format):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: plugin-registry-mirror
  namespace: rhdh-operator
data:
  mirrors.yaml: |
    imageMirrors:
      - source: registry.access.redhat.com/rhdh
        mirrors:
          - mirror.company.com/rhdh
      - source: quay.io/lightspeed-core
        mirrors:
          - mirror.company.com/lightspeed-core
      - source: registry.redhat.io/offline-knowledge-portal
        mirrors:
          - mirror.company.com/okp
```

**Why this layer is needed even with `spec.relatedImages`**:
- `spec.relatedImages` + IDMS/ITMS is the standard resolution path on OpenShift — but it does not work on **Rosa HCP** (hosted control planes block IDMS/ITMS) or **vanilla Kubernetes** (no IDMS/ITMS at all).
- ConfigMap resolution works **everywhere the operator runs** — OpenShift, Rosa HCP, vanilla Kubernetes, kind, minikube.
- It's already proven for dynamic plugins (shipped and working). Extending it to containers is a small incremental change.
- It keeps plugin and container mirroring in one ConfigMap, so users manage one resource for all their mirror mappings.

**Important**: Creating or updating the ConfigMap requires an operator pod restart (to mount the updated ConfigMap volume). Subsequent changes to the ConfigMap content require another restart. This is the same lifecycle as `RELATED_IMAGE_*` env vars — neither approach avoids restarts.

### How the Two Layers Work Together

On a **standard disconnected OpenShift** cluster, the typical flow is:

```
1. oc-mirror reads spec.relatedImages from CSV
   → Copies all listed images to mirror registry

2. oc-mirror creates IDMS/ITMS resources on the cluster
   → CRI-O transparently redirects image pulls to mirror

3. OLM installs operator with RELATED_IMAGE_* env vars
   → Operator reads env vars, uses them for backstage + postgresql
   → For Lightspeed images (new): same pattern, operator reads
     RELATED_IMAGE_lightspeed_core etc.

4. (Optional) User creates plugin-registry-mirror ConfigMap
   → Operator also applies ConfigMap resolution during reconciliation
   → This is additive — both mechanisms coexist safely
```

On **Rosa HCP** or **vanilla Kubernetes** (no IDMS/ITMS available):

```
1. User discovers images from spec.relatedImages (or bundle inspection)
   → Uses skopeo copy to mirror images manually

2. User creates plugin-registry-mirror ConfigMap
   → Maps source registries to mirror registry

3. Operator reads ConfigMap at startup, applies mappings
   → Rewrites all image references during reconciliation
   → Pods see already-resolved mirror paths
```

### Architectural Approach

**Precedence**: When both mechanisms are configured, `RELATED_IMAGE_*` env vars take precedence for the images they cover (backstage, postgresql, and now the Lightspeed images). ConfigMap resolution applies to any remaining image references that env vars don't cover. This matches the existing behavior where the operator checks `os.Getenv()` first, then falls back to the image defined in the flavour ConfigMap.

**When resolution happens**: During reconciliation, after flavour manifests are merged but before Kubernetes objects are applied to the cluster.

**Where in the code**: In each object's `addToModel()` method — the same place the operator already applies `RELATED_IMAGE_*` substitution for core images.

**Scope of ConfigMap resolution**:
- Container images in Deployments (backstage, lightspeed-core sidecar, init containers)
- Container images in StatefulSets (postgresql)
- Container images in plugin-deps (OKP)
- Plugin OCI packages (already working, no change needed)

**Out of scope**:
- npm packages, HTTP URLs (not container images)
- Orchestrator on vanilla Kubernetes documentation (Orchestrator is [currently only supported on OpenShift](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub))

---

## Implementation

### Operator Code Changes ([rhdh-operator](https://github.com/redhat-developer/rhdh-operator))

#### Layer 1: `spec.relatedImages` + `RELATED_IMAGE_*`

| What | Files | Change | Validation |
|------|-------|--------|------------|
| **Add env vars to CSV** | `bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml` | Add `RELATED_IMAGE_lightspeed_core`, `RELATED_IMAGE_lightspeed_rag_init`, `RELATED_IMAGE_okp` env vars to operator deployment spec (same section as existing [`RELATED_IMAGE_backstage`](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L311-L316)) | `make bundle` regenerates `spec.relatedImages` from env vars |
| **Add env var reads in operator code** | Flavour model code (where Lightspeed sidecar, RAG init, OKP containers are configured) | Add `os.Getenv("RELATED_IMAGE_lightspeed_core")` checks, following the pattern in [`deployment.go:31`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L31) | Unit test: env var set → image substituted; env var unset → flavour default used |
| **Bundle generation** | `Makefile` / `make bundle` target | No manual change — `make bundle` automatically reads `RELATED_IMAGE_*` env vars from the CSV deployment spec and populates `spec.relatedImages` | Verify `spec.relatedImages` contains all 5 images after `make bundle` |

#### Layer 2: ConfigMap Mirror Resolution

| What | Files | Change | Validation |
|------|-------|--------|------------|
| **Extend mirror logic** | [`pkg/model/dynamic-plugins-mirror.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins-mirror.go) | Extend `ApplyMirror()` to handle both `oci://`-prefixed refs (plugins) and plain image refs (containers). Currently it only matches `oci://` prefixed strings. | Unit tests: mirror `quay.io/lightspeed-core/lightspeed-stack:0.7.0` → `mirror.company.com/lightspeed-core/lightspeed-stack:0.7.0` |
| **Apply to Deployments** | [`pkg/model/deployment.go:82`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L82) | Add `applyMirrorsToAllContainers()` call in `addToModel()`, after the existing `RELATED_IMAGE_backstage` override | Lightspeed sidecar + init containers use mirrored registry |
| **Apply to StatefulSets** | [`pkg/model/db-statefulset.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/db-statefulset.go) | Add `applyMirrorsToAllContainers()` call in `addToModel()`, after the existing `RELATED_IMAGE_postgresql` override | PostgreSQL uses mirrored registry |
| **Apply to plugin-deps** | [`internal/controller/plugin_dependencies.go`](https://github.com/redhat-developer/rhdh-operator) | Verify OKP deployment flows through the same reconciliation path and receives mirror substitution | OKP deployment uses mirrored registry |
| **Unit tests** | `pkg/model/dynamic-plugins-mirror_test.go` | Add test cases for container image mirror resolution — tags, digests, registry ports, substring matching edge cases | Full coverage for boundary cases |
| **Integration tests** | `tests/e2e/` | Add air-gap scenario: deploy Backstage with intelligent-assistant, verify all images pulled from mirror | E2E test passes with no external registry access |

### Downstream Impact

#### What changes in the bundle

Adding images to `spec.relatedImages` means these images now appear in **two places** in the bundle:

- **ConfigMaps** (flavour-intelligent-assistant, plugin-deps-okp) — already there today
- **CSV `spec.relatedImages`** — new

#### Required downstream updates

| Script | What needs to change | Why |
|--------|---------------------|-----|
| [`sync-midstream.sh`](https://github.com/redhat-developer/rhdh-operator) | Add staleness checks for the new `spec.relatedImages` entries (`lightspeed-core`, `okp`, `lightspeed-rag-init`), following the same pattern used for `postgresql` | Without this, when Red Hat releases new versions of these images, the ConfigMaps will update but the CSV entries will go stale. `oc-mirror` reads from `spec.relatedImages`, so stale entries break the air-gap workflow. |
| [`replaceUpstreamImages.sh`](https://github.com/redhat-developer/rhdh-operator) | **No changes needed** — already handles digest pinning for all image references in the CSV | Existing logic covers new entries automatically |

#### Conforma validation

Adding images to `spec.relatedImages` enables [Conforma](https://redhat.atlassian.net/browse/RHDHSUPP-417) downstream pipeline validation to verify that Lightspeed images come from trusted registries — the same validation already applied to `backstage` and `postgresql`. This is a compliance improvement.

### Documentation Changes ([red-hat-developers-documentation-rhdh](https://github.com/redhat-developer/red-hat-developers-documentation-rhdh))

Documentation follows a **manual-first** pattern: show clear, auditable manual steps using standard tooling (`yq`, `skopeo`, `oc-mirror`), then link to helper scripts (`prepare-restricted-environment.sh`, `mirror-plugins.sh`) as optional automation. Enterprise customers often have security policies against running external scripts — they need transparent steps they can audit and control.

#### Document Two Resolution Paths

Air-gap documentation must explain both resolution paths so users can choose based on their platform:

**Path A: Standard OpenShift (IDMS/ITMS available)**

This is the default path for most disconnected OpenShift clusters. It uses the standard Red Hat operator pattern:

1. **Discover images**: `oc-mirror` reads `spec.relatedImages` from the operator's CSV automatically — no manual image hunting needed
2. **Mirror images**: `oc-mirror` copies all listed images to the customer's mirror registry and creates IDMS/ITMS resources on the cluster
3. **Resolution happens automatically**: IDMS/ITMS tells CRI-O to redirect all pulls from `registry.redhat.io/...` to `mirror.company.com/...`. The operator's `RELATED_IMAGE_*` env vars are also rewritten by OLM. No ConfigMap needed.

```bash
# Standard oc-mirror workflow — same as any other RH operator
oc-mirror --config imageset-config.yaml docker://mirror.company.com
```

**Path B: Rosa HCP / Vanilla Kubernetes / Users wanting dynamic control (no IDMS/ITMS)**

This path uses the ConfigMap mechanism for runtime resolution:

1. **Discover images**: Extract from `spec.relatedImages` in CSV (same source of truth), or inspect bundle ConfigMaps
2. **Mirror images**: Use `skopeo copy` to copy images to mirror registry
3. **Create ConfigMap**: Create `plugin-registry-mirror` ConfigMap with source → mirror mappings
4. **Restart operator**: Restart the operator pod to mount the new ConfigMap
5. **Resolution happens at reconciliation**: Operator reads ConfigMap, rewrites image references in all Kubernetes objects before applying them

```bash
# Mirror images manually
skopeo copy \
  docker://quay.io/lightspeed-core/lightspeed-stack:0.7.0 \
  docker://mirror.company.com/lightspeed-core/lightspeed-stack:0.7.0

# Create ConfigMap
kubectl apply -f plugin-registry-mirror.yaml

# Restart operator to mount ConfigMap
kubectl rollout restart deployment rhdh-operator -n rhdh-operator
```

#### Documentation Updates by Document

| Document | Current State | What Changes |
|----------|---------------|--------------|
| **[Install RHDH in air-gap (Operator)](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_in_an_air-gapped_environment/index#install-rhdh-in-an-air-gapped-environment-with-the-operator_installing-rhdh-in-an-air-gapped-environment)** | Only shows `prepare-restricted-environment.sh` script | Rewrite to manual-first: show `oc-mirror` reading from `spec.relatedImages` (Path A). Add Path B with ConfigMap for Rosa HCP / vanilla K8s. Link to script as optional automation at the end. |
| **[Install RHDH + Intelligent Assistant air-gap](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant)** | Says "mirror these images manually" because script doesn't parse them | Remove manual extraction note (images now in `spec.relatedImages`). Show both paths. Note: OKP is optional and 10+ GB — only mirror if using offline knowledge portal. |
| **[Install Orchestrator air-gap (Operator)](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-operator_orchestrator-in-rhdh)** | Shows OpenShift-only with oc-mirror | Clarify: Orchestrator uses plugin OCI packages (not container images). Plugin packages already supported by existing ConfigMap mirror resolution. No container image changes needed for Orchestrator. |
| **Operator air-gap reference (`.rhdh/docs/airgap.adoc`)** | Incomplete | Add ConfigMap format reference. Document Subscription `spec.config.env` override for `RELATED_IMAGE_*`. Show both Path A and Path B side by side. |
| **[Install RHDH + Orchestrator air-gap (Helm)](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-helm-chart_orchestrator-in-rhdh)** | OpenShift with oc-mirror only | Orchestrator is currently [only supported on OpenShift](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub). No vanilla K8s procedure needed at this time. |

#### Documentation Pattern for Each Doc

Every air-gap document should follow this structure:

1. **Prerequisites** — tools needed: `yq`, `skopeo` or `oc-mirror`, `kubectl` or `oc`
2. **Path A (Standard OpenShift)** — `oc-mirror` reads `spec.relatedImages`, creates IDMS/ITMS, done
3. **Path B (Rosa HCP / Vanilla K8s)** — `skopeo copy` + ConfigMap creation + operator restart
4. **Verification** — how to confirm images are pulling from the mirror
5. **Optional automation** — link to `prepare-restricted-environment.sh` or `mirror-plugins.sh`

### Scripts / Tooling Changes ([rhdh-operator](https://github.com/redhat-developer/rhdh-operator))

| Script | What Changes | Why |
|--------|--------------|-----|
| [`prepare-restricted-environment.sh`](https://github.com/redhat-developer/rhdh-operator/blob/main/.rhdh/scripts/prepare-restricted-environment.sh) | Update to read from `spec.relatedImages` as primary image source, with fallback to old CSV parsing for backward compatibility with older bundles | Once images are in `spec.relatedImages`, the script can discover them automatically instead of requiring manual extraction |
| [`mirror-plugins.sh`](https://github.com/redhat-developer/rhdh-operator/blob/main/.rhdh/scripts/mirror-plugins.sh) | **No changes needed** — already handles plugin OCI packages | Plugins are a separate concern from container images |

### Helm Chart ([rhdh-chart](https://github.com/redhat-developer/rhdh-chart))

**No code or chart changes needed.** Helm users already use [`values.yaml`](https://github.com/redhat-developer/rhdh-chart/blob/main/charts/redhat-developer-hub/values.yaml) as the image inventory source. Existing documentation instructs users to run `helm show values` to discover images. The ConfigMap mirror resolution mechanism is operator-only and does not apply to Helm installs.

### Summary of Changes by Repository

| Repository | Bundle/CSV | Operator Code | Scripts | Documentation |
|------------|------------|---------------|---------|---------------|
| **[rhdh-operator](https://github.com/redhat-developer/rhdh-operator)** | ✏️ Add 3 images to `spec.relatedImages` + `RELATED_IMAGE_*` env vars | ✏️ Add env var reads for new images + extend ConfigMap mirror resolution to containers | ✏️ Update `prepare-restricted-environment.sh` to read from `spec.relatedImages` | ✏️ Rewrite air-gap docs: both paths, manual-first |
| **[rhdh-chart](https://github.com/redhat-developer/rhdh-chart)** | N/A | N/A | N/A | ✅ No changes needed |
| **[rhdh-docs](https://github.com/redhat-developer/red-hat-developers-documentation-rhdh)** | N/A | N/A | N/A | ✏️ Major rewrite: both paths, manual-first, remove "mirror manually" notes |

---

## Alternatives Considered

### Alternative 1: ConfigMap Mirror Resolution Only (no `spec.relatedImages`)

**Approach**: Rely solely on ConfigMap-based runtime resolution. Do not add images to `spec.relatedImages` in the CSV.

This was the approach in the [previous revision of this ADR](https://github.com/redhat-developer/rhdh-adr/pull/29).

**Rejected because**:
1. **Breaks `oc-mirror`**: Customers with standardised disconnected OCP pipelines expect `oc-mirror` to discover all images from `spec.relatedImages`. Without these entries, RHDH is the only Red Hat operator that requires manual image discovery. ([RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417))
2. **Breaks Conforma validation**: Downstream build pipelines use Conforma to verify that all images in `spec.relatedImages` come from trusted registries. Images not in `spec.relatedImages` skip this check.
3. **Non-standard**: Every other Red Hat operator ([OpenTelemetry](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml#L590-L593), [OADP](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml#L1484-L1519), [Quay](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml#L153-L170), [DevWorkspace](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml#L410-L445), [Sandboxed Containers](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml#L420-L437)) uses `spec.relatedImages`. RHDH should not be the exception.

### Alternative 2: `spec.relatedImages` Only (no ConfigMap resolution)

**Approach**: Add images to `spec.relatedImages` and rely entirely on IDMS/ITMS + `RELATED_IMAGE_*` env vars for resolution.

This was the approach in the [first version of this ADR](https://github.com/redhat-developer/rhdh-adr/pull/29/commits/d89a24c).

**Rejected because**:
1. **Does not work on Rosa HCP**: Hosted control planes block IDMS/ITMS. Users on Rosa HCP have no resolution path.
2. **Does not work on vanilla Kubernetes**: No IDMS/ITMS, no OLM — users need an operator-level mechanism.
3. **Inconsistent with plugins**: Dynamic plugin packages already use ConfigMap resolution. Having two different mechanisms (IDMS/ITMS for containers, ConfigMap for plugins) creates user confusion. The ConfigMap should be the unified mechanism for runtime resolution.

### Alternative 3: Document-Only Fixes

**Approach**: Leave code unchanged. Extend documentation with manual image extraction and manual deployment patching for every air-gapped install.

**Rejected because**:
- Does not scale with flavours and plugin-deps
- Guarantees recurring documentation gaps as images change
- Contradicts the operator's purpose (automation)
- Does not address `oc-mirror` / Conforma compliance

---

## Consequences

### Positive

✅ **Standard RH operator compliance**: `spec.relatedImages` + `RELATED_IMAGE_*` follows the pattern used by all other Red Hat operators — `oc-mirror` works out of the box  
✅ **Conforma validation**: Downstream pipelines can verify all operator images come from trusted registries  
✅ **Platform-agnostic resolution**: ConfigMap mechanism works everywhere — OpenShift, Rosa HCP, vanilla Kubernetes  
✅ **Single ConfigMap**: Users manage one `plugin-registry-mirror` ConfigMap for plugins AND container images  
✅ **Optional feature support**: Users only mirror images for features they enable (document OKP as optional)  
✅ **Backward compatible**: Existing `RELATED_IMAGE_*` mechanism for core images continues to work unchanged  
✅ **Future-proofed**: [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) will add mandatory/optional classification to `spec.relatedImages`, solving the OKP size concern natively  
✅ **Transparent documentation**: Manual-first approach with both paths documented; scripts as optional helpers  

### Negative

❌ **CSV maintenance**: Adding images to `spec.relatedImages` increases the bundle maintenance surface — new env vars, digest pinning, staleness checks  
❌ **Two mechanisms to understand**: Users on standard OpenShift don't need to know about ConfigMap resolution, but documentation must cover both paths clearly  
❌ **OKP in `spec.relatedImages` is large**: Until [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) lands, `oc-mirror` will copy the 10+ GB OKP image even if unused (mitigated by documentation + `ImageSetConfiguration` exclusion)  
❌ **Downstream work**: `sync-midstream.sh` needs updates to check staleness of new `spec.relatedImages` entries  
❌ **ConfigMap requires operator restart**: Creating or updating the `plugin-registry-mirror` ConfigMap requires restarting the operator pod to mount the new volume content  

### Neutral

⚖️ **`RELATED_IMAGE_*` env vars remain the primary override**: On standard OpenShift, IDMS/ITMS + env vars handle resolution. ConfigMap is additive, not replacing.  
⚖️ **Operator restart for ConfigMap changes**: Same lifecycle as env var changes — neither approach avoids restarts.  
⚖️ **Dynamic plugins unchanged**: Plugin OCI package mirroring via ConfigMap already works. This ADR extends the mechanism to containers but doesn't change the plugin path.  

---

## References

### Operator Source Code

- [`spec.relatedImages` in CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L498-L502) — current 2-image list
- [`RELATED_IMAGE_*` env vars in CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L311-L316) — current backstage + postgresql
- [`deployment.go` — `RELATED_IMAGE_backstage` read](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L31) — pattern to follow for new images
- [`db-statefulset.go` — `RELATED_IMAGE_postgresql` read](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/db-statefulset.go#L17)
- [`dynamic-plugins-mirror.go` — ConfigMap mirror logic](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins-mirror.go) — extend for containers
- [`dynamic-plugins.go:176` — where mirrors apply to plugins](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins.go#L176)
- [`spec_preprocessor.go:157` — where mirrors are loaded](https://github.com/redhat-developer/rhdh-operator/blob/main/internal/controller/spec_preprocessor.go#L157)
- [`deployment.yaml` — ConfigMap volume mount](https://github.com/redhat-developer/rhdh-operator/blob/main/config/manager/deployment.yaml#L103-L122)
- [Subscription sample](https://github.com/redhat-developer/rhdh-operator/blob/main/config/samples/catalog-subscription-template.yaml) — user override for env vars
- [ClusterExtension sample](https://github.com/redhat-developer/rhdh-operator/blob/main/config/samples/catalog-cluster-extension-template.yaml) — OLM v1 equivalent

### Other Red Hat Operators (spec.relatedImages examples)

- [OpenTelemetry Operator CSV](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml#L590-L593)
- [OADP Operator CSV](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml#L1484-L1519)
- [Quay Operator CSV](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml#L153-L170)
- [DevWorkspace Operator CSV](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml#L410-L445)
- [Sandboxed Containers Operator CSV](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml#L420-L437)

### Jira / Upstream Trackers

- [RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417) — Customer expectation: `oc-mirror` should work for RHDH like all other RH operators
- [RHDHPLAN-1887](https://redhat.atlassian.net/browse/RHDHPLAN-1887) — Centralize air-gap image inventory
- [RHIDP-15003](https://redhat.atlassian.net/browse/RHIDP-15003) — ConfigMap-based mirror resolution for dynamic plugins (already implemented)
- [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) — OCP initiative to add mandatory/optional classification to `spec.relatedImages` (future — will solve OKP size concern natively)

### OpenShift Documentation

- [Disconnected Environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/disconnected_environments/index)
- [OLM in Disconnected Environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index#olm-restricted-networks) — defines `spec.relatedImages` requirement
- [OC Mirror Plugin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/disconnected_environments/index#installation-oc-mirror-installing-plugin_about-installing-oc-mirror-v2)

### RHDH Product Documentation

- [Air-Gapped Operator Installation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_in_an_air-gapped_environment/index#install-rhdh-in-an-air-gapped-environment-with-the-operator_installing-rhdh-in-an-air-gapped-environment)
- [LightSpeed Air-Gap Configuration](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant)
- [Orchestrator Air-Gap Installation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-operator_orchestrator-in-rhdh)

### PR History

- [PR #29 — ADR-009](https://github.com/redhat-developer/rhdh-adr/pull/29) — this ADR's review discussion
- [gazarenkov's review](https://github.com/redhat-developer/rhdh-adr/pull/29#pullrequestreview-5529579002) — "mirror configuration should be a first class citizen... extend ConfigMap approach"
- [rm3l's review](https://github.com/redhat-developer/rhdh-adr/pull/29#pullrequestreview-5701582791) — "we should also provide a supported path for OCP users using oc-mirror... the two approaches are not mutually exclusive"
