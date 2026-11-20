# ADR: List Supported Dependency Images in the Operator CSV

## Context

**Problem**: `oc-mirror` discovers an operator's dependency images from the CSV's
`spec.relatedImages`. The RHDH bundle currently lists RHDH and PostgreSQL, but omits
container images referenced by its supported flavours and plugin dependencies.
Customers must discover and mirror those missing images separately.

For OpenShift clusters with working `ImageDigestMirrorSet` / `ImageTagMirrorSet`
(IDMS/ITMS) configuration, listing the missing images is enough to enable the
standard bundle-based mirroring workflow. The container runtime redirects image
pulls to the mirror; neither OLM nor the RHDH Operator needs to rewrite image
references in workload manifests.

## Decision

**Add the known container images used by the RHDH profile's supported flavours and
plugin dependencies directly to the CSV's `spec.relatedImages`.**

| CSV image name | Used by | Change |
|----------------|---------|--------|
| `backstage` | RHDH application | Already listed |
| `postgresql` | Local database and SonataFlow PostgreSQL client job | Already listed; no duplicate entry needed |
| `flavour-intelligent-assistant-lightspeed-core` | Intelligent Assistant flavour | Add |
| `plugin-dep-okp` | Optional Intelligent Assistant OKP dependency | Add |
| `plugin-dep-tekton-ubi-minimal` | Tekton dependency tasks | Add |
| `plugin-dep-tekton-git` | Tekton `git-cli` task's default image | Add |

**Implementation approach**:

- Declare the additional entries in the **base CSV**, and ensure `make bundle`
  preserves them in the generated bundle. Their references must match the images
  already used by that release's flavour and dependency manifests.
- Do **not** add environment variables for these entries. A `RELATED_IMAGE_*`
  variable implies that the operator consumes an override, which this fix does
  not implement. Existing RHDH and PostgreSQL overrides remain unchanged.
- Do **not** change templates, reconciliation, or workload image defaults.
- Keep `plugin-installer` excluded while it is Dev Preview.

The workflow is: run `oc-mirror` for the RHDH operator, apply the generated cluster
mirror configuration, then install RHDH. This fix applies only where that mirror
configuration can be used. The same CSV-only approach can be backported to 1.10
and 2.1 using each release's actual image references.

## Alternatives Considered

### Alternative 1: Documentation-only image lists

- **Approach**: Document the missing images in the disconnected-installation guide
  instead of listing them in the CSV.
- **Rejected because**: Customers keep a separate, manual discovery step, and the
  images remain undiscoverable through the operator bundle.

### Alternative 2: Runtime image overrides, template helpers, or ConfigMap-based resolution

- **Approach**: Let the operator resolve or rewrite image references at
  reconciliation time (`RELATED_IMAGE_*` overrides, template helpers, or mirror
  ConfigMaps).
- **Deferred for separate design work because**: These address a broader problem —
  clusters where node-level mirror configuration is unavailable — and must consider
  dynamic plugin ownership.

## Consequences

### Positive

- ✅ Standard `oc-mirror` discovery covers the known supported container images
  listed above without changing operator runtime behaviour.

### Negative

- ❌ `oc-mirror` mirrors all related images, including optional dependencies such as
  OKP, even when their flavour is disabled. Individual related images
  cannot currently be excluded; optional-image support is tracked in
  [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755).
- ❌ Maintainers must keep the CSV list aligned with the shipped manifests. Product
  bundles must use trusted, digest-pinned images and pass downstream Conforma
  validation before release.

### Neutral

- ⚖️ This does not add overrides for the newly listed images or solve disconnected
  installs where IDMS/ITMS cannot be used. Dynamic plugin OCI artifacts, custom
  plugin dependencies, images owned by other operators, runtime downloads, Helm,
  and changes to the existing mirroring script remain out of scope; ADR-12 handles
  the per-installation plugin-dependency images.

## References

- [Feature request: RHDHPLAN-1887](https://redhat.atlassian.net/browse/RHDHPLAN-1887)
- [Implementation: rhdh-operator#4023](https://github.com/redhat-developer/rhdh-operator/pull/4023)
- [ADR-12: Airgap Plugin Resources Image Mirroring](https://github.com/redhat-developer/rhdh-adr/pull/34)
- [RHDH base CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/config/manifests/rhdh/bases/backstage-operator.clusterserviceversion.yaml)
- [RHDH flavour and dependency manifests](https://github.com/redhat-developer/rhdh-operator/tree/main/config/profile/rhdh)
