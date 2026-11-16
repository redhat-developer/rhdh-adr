# ADR: Airgap Plugin Resources Image Mirroring

## Context

**Problem**: RHDH deployments in air-gapped environments cannot pull container images from external registries (quay.io, docker.io, registry.redhat.io).

**Scope**: This ADR addresses **plugin dependency container images only** (databases, sidecars, task runners). Plugin OCI artifact mirroring is **out of scope** - it is already solved via existing mechanisms (`pkg/model/dynamic-plugins-mirror.go`).

In disconnected clusters, plugins deploy runtime dependencies as container images. These dependencies vary per installation (based on enabled plugins and flavours), making them impossible to declare statically in the operator's CSV `relatedImages`.

**Who is impacted**:
- OpenShift users deploying in disconnected environments
- Kubernetes users in air-gapped networks

**Constraints**:
- OpenShift priority, then vanilla Kubernetes
- Must handle dynamic plugin dependencies
- Requires cluster-admin permissions (IDMS/ITMS and DaemonSet are cluster-scoped)

## Decision

Address both aspects of airgapping plugin resources: **mirroring** (copying images to internal registry) and **resolving** (redirecting image pulls to use mirrors).

### Aspect 1: Mirroring (Copy Images)

**OpenShift:**
- Use **oc-mirror** for operator and plugin dependency images
- Generates ImageSetConfiguration from discovered plugin dependencies
- Automatically creates IDMS/ITMS during mirroring

**Kubernetes:**
- Use **skopeo** as reference mirroring tool
- Manual mirror list generation from plugin metadata
- Alternative: any registry sync tool (harbor, etc.)

### Aspect 2: Resolving (Redirect Image Pulls)

**Phase 1: oc-mirror / OpenShift**
- Use **IDMS/ITMS** via oc-mirror for runtime-level image pull redirection
- CRI-O configuration, most reliable
- oc-mirror handles automatically
- Requires cluster-admin permissions

**Phase 2: DaemonSet / Kubernetes**
- Deploys privileged DaemonSet to write `/etc/containers/registries.conf.d/` on each node
- Runtime-level enforcement at containerd/CRI-O level
- Requires cluster-admin permissions

**Phase 3: Webhook / HyperShift - OUT OF SCOPE**
- MutatingAdmissionWebhook approach considered but deferred
- Not reliable enough for production (see Alternative 2 below)
- Can be reconsidered in future ADR if customer demand exists

## Alternatives Considered

### Alternative 1: Template-Based Rewriting
- **Approach**: Extend operator's Go template system with `{{ ImageMirror "image" }}` function in ConfigMaps
- **Rejected because**: Only catches operator-created resources. Misses user-provided CRs, Tekton tasks, plugin-created resources. Incomplete coverage for dynamic environment.

### Alternative 2: MutatingWebhook Approach
- **Approach**: MutatingAdmissionWebhook intercepts pod creation at API level and rewrites image references. Could work on HyperShift with hosted-cluster-admin permissions.
- **Deferred for future consideration because**: Not reliable enough for production use. Adds API overhead, requires certificate management, misses pods created before webhook deployment, and introduces race conditions. Runtime-level solutions (IDMS/DaemonSet) are significantly more reliable. HyperShift air-gap support can be reconsidered in a future ADR if there is proven demand and webhook reliability concerns are addressed.

### Alternative 3: Static relatedImages
- **Approach**: Pre-declare all possible plugin dependencies in operator CSV
- **Rejected because**: Plugin dependencies are dynamic and installation-specific. Would require listing every possible database, cache, and sidecar image (100+ images), most unused in any given deployment.

## Consequences

### Positive
- ✅ Reuses standard OpenShift tooling (oc-mirror, IDMS/ITMS) - no RHDH-specific implementation
- ✅ Runtime-level redirection for maximum reliability
- ✅ Consistent configuration format across both platforms

### Negative
- ❌ Requires cluster-admin on both platforms (IDMS/ITMS and DaemonSet are cluster-scoped)
- ❌ Different implementation per platform (IDMS vs DaemonSet)
- ❌ No HyperShift support in this ADR

### Neutral
- ⚖️ Kubernetes users need DaemonSet deployment for runtime-level configuration
- ⚖️ Helper script for dependency discovery is planned but not required (manual list also works)

## Notes

**Out of scope - Plugin OCI artifacts**: This ADR only covers plugin dependency container images. Plugin OCI artifact mirroring (the `oci://` packaged plugins themselves) is already solved via existing mechanisms and is not addressed here.

**Out of scope - HyperShift and webhook implementation**: HyperShift hosted cluster deployments are not supported in this ADR. In HyperShift, nodes are managed by the management cluster, preventing hosted-cluster-admin from deploying privileged DaemonSets or creating IDMS/ITMS. While a MutatingWebhook approach could theoretically work for HyperShift, it is **not reliable enough for production use** and therefore **out of scope for implementation**. The webhook approach has significant reliability concerns: API-level overhead, certificate management complexity, race conditions with pod creation, and missed pods created before webhook deployment. HyperShift air-gap support via webhook can be reconsidered in a future ADR if there is proven customer demand and webhook reliability concerns are addressed.

**Mirroring order**: Operator images and defaults must be mirrored first (via standard oc-mirror catalog workflow). Plugin dependency discovery happens second, after operator deployment, because dependency resolution requires the operator's default-config, flavours, and plugin metadata.

## References

- OpenShift disconnected docs: https://docs.openshift.com/container-platform/latest/installing/disconnected_install/
- oc-mirror: https://docs.openshift.com/container-platform/latest/installing/disconnected_install/installing-mirroring-disconnected.html
