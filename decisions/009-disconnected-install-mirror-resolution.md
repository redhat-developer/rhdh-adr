# ADR-009: Disconnected Install: Extend `spec.relatedImages` to All Operator-Managed Container Images

## Executive Summary / TL;DR

Add the operator-managed container images that are required by default to the CSV's `spec.relatedImages` and honour the corresponding `RELATED_IMAGE_*` environment variables in the operator's controller code. This is the standard Red Hat operator pattern for disconnected (air-gapped) environments.

**Images to add** (2 entries for RHDH 2.1+):
- `lightspeed-core` — the Lightspeed AI service sidecar
- `okp` — the optional Offline Knowledge Portal deployment for the `intelligent-assistant-okp` flavour

`okp` remains optional from a product perspective: the base Intelligent Assistant is enabled by default in [Enabling Intelligent Assistant](https://github.com/redhat-developer/rhdh-operator/blob/main/docs/intelligent-assistant.md), while OKP is explicitly disabled unless the `intelligent-assistant-okp` add-on is selected as documented in [Enabling OKP on OpenShift](https://github.com/redhat-developer/rhdh-operator/blob/main/docs/intelligent-assistant-okp-openshift.md). Even so, as Armel noted, it should still be discoverable via `spec.relatedImages` because the operator ships it and customers need a standard way to mirror and override it when they enable the add-on. The RAG init container image (`lightspeed-rag-init`) was removed in RHDH 2.1 and is no longer shipped.

**What this gives users**:
- **OpenShift**: `oc-mirror` discovers the default images automatically from `spec.relatedImages`. On clusters where IDMS works, resolution is transparent. On clusters where IDMS does not work (e.g., Rosa HCP), users override via Subscription or ClusterExtension `spec.config.env`.
- **Vanilla Kubernetes**: Users extract the image list from `spec.relatedImages` with a one-liner, mirror with their own tooling, and override `RELATED_IMAGE_*` env vars on the operator deployment.
- **Optional OKP flavour**: When the `intelligent-assistant-okp` add-on is enabled, customers mirror the OKP image explicitly and set `RELATED_IMAGE_okp` as needed. It remains a flavour-specific concern, but it is still discoverable through `spec.relatedImages` so the standard disconnected workflow works consistently.

**What this does NOT include**: Extending the ConfigMap-based mirror resolution (currently used for dynamic plugin OCI packages) to container images. After team discussion, this was determined to be unnecessary — the `RELATED_IMAGE_*` env var override mechanism already covers all platforms, and extending the ConfigMap approach to containers risks reinventing IDMS and creating user confusion. The existing ConfigMap mechanism for plugin OCI packages remains unchanged and is not affected by this ADR.

**Script deprecation**: The `prepare-restricted-environment.sh` helper script will be deprecated in 2.2 and removed from documentation and the operator repository in 2.3. It may be migrated internally to [rhdh-core](https://github.com/redhat-developer/rhdh) for E2E testing and Helm chart support.

---

## Context

### The Air-Gap Problem in Plain Terms

When an organisation runs RHDH on a network with no internet access (a "disconnected" or "air-gapped" environment), every container image the operator needs must be pre-copied to an internal mirror registry. This involves three steps:

1. **Discover** — Figure out which images are needed
2. **Mirror** — Copy those images from the public registry to the internal registry
3. **Resolve** — Tell the running operator and its pods where to pull from (the mirror, not the internet)

Today, RHDH has gaps in discovery and resolution for Lightspeed / Intelligent Assistant images.

### What Works Today

**Core images (2 of them)** — `backstage` and `postgresql` — follow the standard OpenShift pattern end-to-end:

- ✅ Listed in CSV [`spec.relatedImages`](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml) (discoverable by `oc-mirror`)
- ✅ Declared as [`RELATED_IMAGE_*` env vars](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml) on the operator deployment (resolved by OLM + IDMS/ITMS at runtime)
- ✅ Operator code reads these env vars and substitutes them into the Backstage Deployment ([`deployment.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L112-L114)) and PostgreSQL StatefulSet ([`db-statefulset.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/db-statefulset.go#L17))

### What Does Not Work Today

**Lightspeed / Intelligent Assistant images (2 of them in 2.1+)** are invisible to standard tooling:

| Image | Size | Source | Problem |
|-------|------|--------|---------|
| `lightspeed-core` sidecar | ~1 GB | [Flavour ConfigMap](https://github.com/redhat-developer/rhdh-operator/tree/main/config/profile/rhdh/default-config/flavours/intelligent-assistant) | Not in `spec.relatedImages`, not discoverable by `oc-mirror`, operator code does not read a `RELATED_IMAGE_*` env var for it |
| OKP deployment | 10+ GB | [plugin-deps ConfigMap](https://github.com/redhat-developer/rhdh-operator/blob/main/config/profile/rhdh/plugin-deps/okp.yaml) | Not in `spec.relatedImages`, not discoverable by `oc-mirror`, operator code does not read a `RELATED_IMAGE_*` env var for it |

These images exist only inside bundle ConfigMaps. Users must manually extract them from the bundle to discover what to mirror — and even after mirroring, there is no override mechanism for them. The current [air-gap documentation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant) acknowledges this gap:

> "The `prepare-restricted-environment.sh` script does **not automatically parse Developer Lightspeed for RHDH images from the bundle manifest**, so mirror these images manually before running the script."

### Why This Matters to Customers

From [RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417): customers managing multiple disconnected OpenShift clusters use `oc-mirror` as their standardised mirroring workflow for all Red Hat operators. They expect RHDH to work the same way. When Lightspeed images are missing from `spec.relatedImages`, their established workflow breaks — RHDH becomes the exception they have to handle manually.

### What Other Red Hat Operators Do

The `spec.relatedImages` + `RELATED_IMAGE_*` pattern is the standard across Red Hat's operator portfolio:

- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml#L590-L593)
- [OADP Operator](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml#L1484-L1519)
- [Quay Operator](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml#L153-L170)
- [DevWorkspace Operator](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml#L410-L445)
- [Sandboxed Containers Operator](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml#L420-L437)

RHDH should follow this established pattern, see OCP docs, [Chapter 10. Using Operator Lifecycle Manager in disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index#olm-restricted-networks:~:text=List%20any%20related%20images%2C%20or%20other%20container%20images%20that%20the%20Operator%20might%20require%20to%20perform%20their%20functions%2C%20in%20the%20relatedImages%20parameter%20of%20its%20ClusterServiceVersion%20%28CSV%29%20object%2E).

---

## Decision

### Extend `spec.relatedImages` and honour `RELATED_IMAGE_*` env vars for all operator-managed container images

This is a single, consistent approach that works on OpenShift (standard and Rosa HCP) and vanilla Kubernetes. No additional runtime resolution mechanism is needed for the container images the operator ships. The key review concern is not whether the image should be discoverable, but whether it is required for the default install. We therefore include both `lightspeed-core` and `okp` in `spec.relatedImages` for discoverability and mirror automation, while documenting that OKP remains optional and is only needed when the `intelligent-assistant-okp` add-on is enabled. This matches the product behavior documented in [Enabling Intelligent Assistant](https://github.com/redhat-developer/rhdh-operator/blob/main/docs/intelligent-assistant.md) and [Enabling OKP on OpenShift](https://github.com/redhat-developer/rhdh-operator/blob/main/docs/intelligent-assistant-okp-openshift.md).

**Images to add to the CSV**:

```yaml
# In CSV spec.relatedImages (digest-pinned in downstream builds):
- image: registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9@sha256:...
  name: lightspeed-core
- image: registry.redhat.io/offline-knowledge-portal/rhokp-rhel9@sha256:...
  name: okp
```

```yaml
# Corresponding env vars on the operator deployment in the CSV:
- name: RELATED_IMAGE_lightspeed_core
  value: registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9@sha256:...
- name: RELATED_IMAGE_okp
  value: registry.redhat.io/offline-knowledge-portal/rhokp-rhel9@sha256:...
```

**Operator code**: For each image, the controller code reads the `RELATED_IMAGE_*` env var and, if set, uses it instead of the default image from the flavour ConfigMap. This follows the existing pattern in [`deployment.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L31):

```go
const LightspeedCoreImageEnvVar = "RELATED_IMAGE_lightspeed_core"

// In the flavour's addToModel() or equivalent:
if os.Getenv(LightspeedCoreImageEnvVar) != "" {
    container.Image = os.Getenv(LightspeedCoreImageEnvVar)
}
```

**`make bundle`** automatically generates `spec.relatedImages` from the `RELATED_IMAGE_*` env vars in the CSV deployment spec — no manual maintenance of the default `spec.relatedImages` list is required.

### How This Works on Each Platform

#### OpenShift (standard — IDMS works)

This is the default path for most disconnected OpenShift clusters:

1. **Discover**: `oc-mirror` reads `spec.relatedImages` from the CSV automatically
2. **Mirror**: `oc-mirror` copies all listed images to the customer's mirror registry
3. **Resolve**: `oc-mirror` creates IDMS/ITMS resources on the cluster. CRI-O transparently redirects image pulls. OLM also rewrites the `RELATED_IMAGE_*` env vars on the operator pod. The operator reads these env vars and uses them when creating Kubernetes objects.

No manual steps beyond running `oc-mirror`. This is exactly how every other Red Hat operator works.

#### OpenShift (Rosa HCP or other clusters where IDMS does not work)

IDMS/ITMS are unavailable on Rosa HCP because the control plane is managed. But users can still use `oc-mirror` to copy images, and then override the operator's env vars:

1. **Discover & Mirror**: Same as above — `oc-mirror` copies images from `spec.relatedImages`
2. **Resolve**: Instead of IDMS, the user overrides `RELATED_IMAGE_*` env vars via the Subscription (OLM v0) or ClusterExtension (OLM v1):

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
      - name: RELATED_IMAGE_backstage
        value: mirror.company.com/rhdh/rhdh-hub-rhel9@sha256:...
      - name: RELATED_IMAGE_postgresql
        value: mirror.company.com/rhdh/postgresql-15@sha256:...
      - name: RELATED_IMAGE_lightspeed_core
        value: mirror.company.com/lightspeed-core/lightspeed-stack-rhel9@sha256:...
      - name: RELATED_IMAGE_okp
        value: mirror.company.com/offline-knowledge-portal/rhokp-rhel9@sha256:...
```

The operator reads these env vars and uses them in the Kubernetes objects it creates. No IDMS required.

#### Vanilla Kubernetes (no OLM, no IDMS)

Customers not on OpenShift typically do not want to use `oc`-related tools. The workflow is:

1. **Discover**: Extract the image list from `spec.relatedImages` in the CSV with a one-liner:
   ```bash
   # Extract all related images from the CSV
   yq eval '.spec.relatedImages[].image' backstage-operator.clusterserviceversion.yaml
   ```
2. **Mirror**: Users copy images to their mirror registry using their own tooling (skopeo, crane, or whatever their organisation standardises on). We do not prescribe a specific tool.
3. **Resolve**: Set `RELATED_IMAGE_*` env vars on the operator deployment, pointing at the mirrored images.

### OKP Image Size (10+ GB)

OKP is an optional flavour component, but it is still included in `spec.relatedImages` for standard discovery and mirroring because the operator ships the image and customers need to know exactly what to mirror when they enable the `intelligent-assistant-okp` add-on. This resolves the review concern without losing the standard `oc-mirror` workflow: the image is discoverable, but it is not required for the default base install.

**Mitigations**:
1. **Now**: Document clearly that OKP is optional and only required when the `intelligent-assistant-okp` flavour is enabled. Users who do not enable it can exclude it from their `ImageSetConfiguration` if they want a leaner disconnected mirror set.
2. **Future**: [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) — the OCP team is planning to add mandatory vs optional classification for `spec.relatedImages`. Once available, we can mark OKP as optional so `oc-mirror` can skip it by default while still exposing it for flavour-specific use.

### Orchestrator

Orchestrator is [only supported on OpenShift](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub). It uses plugin OCI packages (not additional container images managed by the RHDH operator). The OSL (OpenShift Serverless Logic) operators have their own `spec.relatedImages` and their own air-gap process — it is not RHDH's responsibility to list OSL operator images in our bundle.

The current [Orchestrator air-gap documentation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-operator_orchestrator-in-rhdh) can remain as-is for now. There is a known gap where IDMS does not apply to plugin OCI packages (because they are pulled inside containers, not by the kubelet), but the ConfigMap mirror resolution for plugins is still dev preview in 2.1 and should not be documented as a production workaround until it reaches GA. This can be addressed as a follow-up.

---

## Implementation

### Operator Code Changes ([rhdh-operator](https://github.com/redhat-developer/rhdh-operator))

| What | Files | Change | Validation |
|------|-------|--------|------------|
| **Add env vars to CSV** | `bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml` | Add `RELATED_IMAGE_lightspeed_core` and `RELATED_IMAGE_okp` env vars to operator deployment spec (same section as existing [`RELATED_IMAGE_backstage`](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L311-L316)) | `make bundle` regenerates `spec.relatedImages` with all 4 images |
| **Add env var reads in controller code** | Flavour model code (where Lightspeed sidecar and OKP containers are configured) | Add `os.Getenv("RELATED_IMAGE_lightspeed_core")` and `os.Getenv("RELATED_IMAGE_okp")` checks, following the pattern in [`deployment.go:31`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L31) | Unit test: env var set → image substituted; env var unset → flavour default used |
| **Bundle generation** | `Makefile` / `make bundle` target | No manual change — `make bundle` reads `RELATED_IMAGE_*` env vars from the CSV deployment spec and populates `spec.relatedImages` | Verify `spec.relatedImages` contains all 4 images after `make bundle` |
| **E2E tests** | `tests/e2e/` | Update disconnected E2E test to verify all images (including Lightspeed) are pulled from mirror when `RELATED_IMAGE_*` env vars are set | E2E test passes with no external registry access |

### Script Deprecation ([rhdh-operator](https://github.com/redhat-developer/rhdh-operator))

| What | Timeline | Detail |
|------|----------|--------|
| **Update `prepare-restricted-environment.sh`** | 2.2 | Add `spec.relatedImages` as primary image source (backward-compatible fallback to old CSV parsing for older bundles) and ensure e2e works as expected|
| **Deprecation notice** | 2.2 release notes | Note that the script is deprecated and will be removed in 2.3. Document the manual `spec.relatedImages`-based workflow as the replacement. |
| **Remove from docs and repo** | 2.3 | Remove the script from customer-facing documentation and the operator repository. Optionally migrate to [rhdh-core](https://github.com/redhat-developer/rhdh) for internal E2E testing and Helm chart air-gap testing. |
| **`mirror-plugins.sh`** | No change | Remains available for plugin OCI packages. Separate concern from container images. |

### Downstream Impact

| Script | What needs to change | Why |
|--------|---------------------|-----|
| `sync-midstream.sh` | Add staleness checks for the 2 new `spec.relatedImages` entries (`lightspeed-core`, `okp`), following the same pattern used for `postgresql` | Without this, when Red Hat releases new versions of these images, the ConfigMaps will update but the CSV entries will go stale. `oc-mirror` reads from `spec.relatedImages`, so stale entries break the air-gap workflow. |
| `replaceUpstreamImages.sh` | **No changes needed** — already handles digest pinning for all image references in the CSV | Existing logic covers new entries automatically |

**Conforma validation**: Adding images to `spec.relatedImages` enables [Conforma](https://conforma.dev/) downstream pipeline validation to verify that Lightspeed images come from trusted registries — the same validation already applied to `backstage` and `postgresql`.

### Documentation Changes ([red-hat-developers-documentation-rhdh](https://github.com/redhat-developer/red-hat-developers-documentation-rhdh))

| Document | Current State | What Changes |
|----------|---------------|--------------|
| **[Install RHDH in air-gap (Operator)](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_in_an_air-gapped_environment/index#install-rhdh-in-an-air-gapped-environment-with-the-operator_installing-rhdh-in-an-air-gapped-environment)** | Only shows `prepare-restricted-environment.sh` script | Rewrite to show: (1) OpenShift — `oc-mirror` reads `spec.relatedImages`, creates IDMS, done. (2) Where IDMS doesn't work — override `RELATED_IMAGE_*` via Subscription/ClusterExtension. (3) Vanilla K8s — extract images from `spec.relatedImages`, mirror, set env vars. Add deprecation notice for script. |
| **[Install RHDH + Intelligent Assistant air-gap](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant)** | Says "mirror these images manually" | Remove manual extraction note — images are now in `spec.relatedImages` and discovered automatically by `oc-mirror`. Document that OKP is optional (10+ GB) — only needed if enabling offline knowledge portal. |
| **[Orchestrator air-gap (Operator)](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-operator_orchestrator-in-rhdh)** | OpenShift with oc-mirror | Leave as-is for now. Plugin OCI packages are a separate concern (IDMS doesn't apply to them). Follow-up when ConfigMap plugin mirror resolution reaches GA. |
| **Operator air-gap reference (`.rhdh/docs/airgap.adoc`)** | Incomplete | Document the Subscription/ClusterExtension `spec.config.env` override pattern with examples for all `RELATED_IMAGE_*` env vars. |

### Helm Chart ([rhdh-chart](https://github.com/redhat-developer/rhdh-chart))

**No changes needed.** Helm users already use [`values.yaml`](https://github.com/redhat-developer/rhdh-chart/blob/main/charts/redhat-developer-hub/values.yaml) as the image inventory source. Existing documentation instructs users to run `helm show values` to discover images.

---

## Alternatives Considered

### Alternative 1: ConfigMap Mirror Resolution for Container Images

**Approach**: Extend the existing `plugin-registry-mirror` ConfigMap mechanism (currently used for plugin OCI packages) to also rewrite container image references during reconciliation.

This was the approach in [earlier revisions of this ADR](https://github.com/redhat-developer/rhdh-adr/pull/29).

**Rejected because**:
1. **Reinvents IDMS**: The ConfigMap approach replicates what IDMS already does (rewrite image references at runtime) but with a different, operator-specific mechanism. Users familiar with IDMS would find this confusing, and behavioural differences between the two create hard-to-debug issues.
2. **Unnecessary**: The `RELATED_IMAGE_*` env var override via Subscription/ClusterExtension already works on all platforms — standard OpenShift, Rosa HCP, and vanilla Kubernetes. There is no gap that ConfigMap resolution would fill for container images.
3. **Still dev preview**: The ConfigMap mechanism for plugins is [dev preview in 2.1](https://redhat.atlassian.net/browse/RHIDP-15003). Extending it to container images before GA would be premature.
4. **Added complexity**: Two parallel resolution mechanisms (env vars and ConfigMap) makes documentation, testing, and support harder. One mechanism is simpler.

### Alternative 2: ConfigMap Mirror Resolution Only (no `spec.relatedImages`)

**Approach**: Rely solely on ConfigMap-based runtime resolution. Do not add images to `spec.relatedImages`.

**Rejected because**:
1. **Breaks `oc-mirror`**: Customers expect `oc-mirror` to discover all images from `spec.relatedImages`. ([RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417))
2. **Breaks Conforma validation**: Downstream pipelines can't verify images not listed in `spec.relatedImages`.
3. **Non-standard**: Every other Red Hat operator uses `spec.relatedImages`. RHDH should not be the exception.

### Alternative 3: Document-Only Fixes

**Approach**: Leave code unchanged. Add manual image extraction steps to documentation.

**Rejected because**:
- Does not scale with flavours and plugin-deps
- Guarantees recurring documentation gaps as images change
- Contradicts the operator's purpose (automation)
- Does not address `oc-mirror` / Conforma compliance

---

## Consequences

### Positive

✅ **Standard RH operator compliance**: `spec.relatedImages` + `RELATED_IMAGE_*` follows the pattern used by all other Red Hat operators  
✅ **`oc-mirror` works out of the box**: Customers' existing disconnected workflows discover all RHDH images automatically  
✅ **Conforma validation**: Downstream pipelines verify all operator images come from trusted registries  
✅ **Single mechanism**: One approach (`RELATED_IMAGE_*` env vars) works on OpenShift, Rosa HCP, and vanilla K8s — no parallel mechanisms to learn  
✅ **Backward compatible**: Existing core image handling (`backstage`, `postgresql`) continues unchanged  
✅ **Future-proofed**: [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) will add mandatory/optional classification to `spec.relatedImages`, solving the OKP size concern natively  
✅ **Script deprecation**: Simplifies maintenance — the script was not widely used by customers and added support burden  

### Negative

❌ **CSV maintenance**: New env vars, digest pinning, staleness checks in `sync-midstream.sh`  
❌ **OKP image is large**: Until [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) lands, `oc-mirror` copies the 10+ GB OKP image even if unused (mitigated by documentation + `ImageSetConfiguration` exclusion)  
❌ **Downstream work**: `sync-midstream.sh` needs updates for new `spec.relatedImages` entries  
❌ **E2E test updates**: Disconnected E2E tests need to cover the new images and env var overrides  

### Neutral

⚖️ **Plugin OCI packages remain separate**: The existing ConfigMap-based mirror resolution for plugins is unaffected. Plugins and container images use different mechanisms — this is correct because they have different pull paths (skopeo inside a container vs kubelet).  
⚖️ **Script deprecation is phased**: 2.2 deprecation → 2.3 removal gives users time to migrate.  

---

## References

### Operator Source Code

- [`spec.relatedImages` in CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L498-L502) — current 2-image list
- [`RELATED_IMAGE_*` env vars in CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml#L311-L316) — current backstage + postgresql
- [`deployment.go` — `RELATED_IMAGE_backstage` read](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go#L31) — pattern to follow for new images
- [`db-statefulset.go` — `RELATED_IMAGE_postgresql` read](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/db-statefulset.go#L17)
- [`dynamic-plugins-mirror.go` — ConfigMap mirror logic for plugins](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins-mirror.go) — not extended for container images
- [Subscription sample](https://github.com/redhat-developer/rhdh-operator/blob/main/config/samples/catalog-subscription-template.yaml) — user override for env vars
- [ClusterExtension sample](https://github.com/redhat-developer/rhdh-operator/blob/main/config/samples/catalog-cluster-extension-template.yaml) — OLM v1 equivalent
- [`prepare-restricted-environment.sh`](https://github.com/redhat-developer/rhdh-operator/blob/main/.rhdh/scripts/prepare-restricted-environment.sh) — script to be deprecated

### Other Red Hat Operators (spec.relatedImages examples)

- [OpenTelemetry Operator CSV](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml#L590-L593)
- [OADP Operator CSV](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml#L1484-L1519)
- [Quay Operator CSV](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml#L153-L170)
- [DevWorkspace Operator CSV](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml#L410-L445)
- [Sandboxed Containers Operator CSV](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml#L420-L437)

### Jira / Upstream Trackers

- [RHDHPLAN-1887](https://redhat.atlassian.net/browse/RHDHPLAN-1887) — Centralize air-gap image inventory
- [RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417) — Customer expectation: `oc-mirror` should work for RHDH like all other RH operators
- [RHIDP-15003](https://redhat.atlassian.net/browse/RHIDP-15003) — ConfigMap-based mirror resolution for dynamic plugins (dev preview, not extended to containers)
- [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) — OCP initiative to add mandatory/optional classification to `spec.relatedImages`

### OpenShift Documentation

- [Disconnected Environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/disconnected_environments/index)
- [OLM in Disconnected Environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index#olm-restricted-networks) — defines `spec.relatedImages` requirement
- [OC Mirror Plugin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/disconnected_environments/index#installation-oc-mirror-installing-plugin_about-installing-oc-mirror-v2)

### RHDH Product Documentation

- [Air-Gapped Operator Installation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_in_an_air-gapped_environment/index#install-rhdh-in-an-air-gapped-environment-with-the-operator_installing-rhdh-in-an-air-gapped-environment)
- [LightSpeed Air-Gap Configuration](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant)
- [Orchestrator Air-Gap Installation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-operator_orchestrator-in-rhdh)
