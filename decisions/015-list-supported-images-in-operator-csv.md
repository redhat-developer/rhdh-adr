# ADR: List Supported Dependency Images in the Operator CSV

## Context

**Problem**: `oc-mirror v2` discovers an operator's dependency images from the
published file-based catalog's bundle metadata, populated from the CSV's
`spec.relatedImages`. The RHDH bundle currently lists RHDH and PostgreSQL, but omits
container images referenced by its shipped flavours and plugin dependencies.
Customers must discover and mirror those missing images separately.

This decision fixes discovery of the listed images, not the full disconnected
installation path. Image pulls must be checked separately: `ImageTagMirrorSet`
(ITMS) redirects tag pulls, while `ImageDigestMirrorSet` (IDMS) redirects digest
pulls. The container runtime applies those rules without rewriting workload
manifests. Pinning a CSV entry to a digest does not change a workload's tag pull
into a digest pull.

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

**Implementation approach**:

- Declare the additional entries in the **base CSV**, and ensure `make bundle`
  preserves them in the generated bundle and catalog publication carries them
  into the matching bundle's metadata. Use release-specific references and record
  any mismatch with workload references as a separate runtime gap.
- Do **not** add environment variables solely for discovery: `oc-mirror v2` does
  not require matching `RELATED_IMAGE_*` variables. A Subscription can set
  variables through [`spec.config.env`](https://github.com/operator-framework/operator-lifecycle-manager/blob/master/doc/design/subscription-config.md#env),
  but they only change deployed images if the operator consumes them. Working
  overrides are deferred to the runtime-resolution design (Alternative 2).
  Existing RHDH and PostgreSQL overrides remain unchanged.
- Do **not** change templates, reconciliation, or workload image defaults.
- Keep `plugin-installer` excluded while it is Dev Preview.
- Keep the Tekton `git-cli` task's default image excluded. It is marked for
  deprecation in
  [tekton.yaml](https://github.com/redhat-developer/rhdh-operator/blob/main/config/profile/rhdh/plugin-deps/tekton.yaml),
  would likely fail downstream Conforma validation, and would commit the bundle
  to mirroring an image that will eventually be dropped. Customers who use the
  `git-cli` task in a disconnected environment mirror it manually.

The same discovery-only approach can be backported to 1.10 and 2.1 using each
release's image references. Successful discovery does not prove that those
releases' workloads can pull from a mirror.

### Validation

- Regenerate and validate the bundles with `make bundles build-installers` in the
  operator repository, and check that the listed entries remain in the RHDH CSV.
- Inspect the published file-based catalog's matching bundle metadata for those
  entries, then verify that `oc-mirror v2` mirrors them.
- Test workload pulls separately in a disconnected install. Use ITMS for tag
  pulls and IDMS for digest pulls, and verify that the mirror serves the exact
  references the workloads request, without falling back to the source registry.

Record catalog-discovery and workload-pull results separately; bundle generation
alone does not establish either result.

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

- ✅ Standard `oc-mirror v2` discovery covers the known shipped container images
  listed above without changing operator runtime behaviour.

### Negative

- ❌ `oc-mirror` mirrors all related images, including optional dependencies such as
  OKP, even when their flavour is disabled. Individual related images
  cannot currently be excluded; optional-image support is tracked in
  [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755).
- ❌ Maintainers must keep the CSV list aligned with the shipped manifests. Product
  bundles must use trusted, digest-pinned images and pass downstream Conforma
  validation before release.
- ❌ The CSV lists `registry.access.redhat.com/ubi10-minimal:10.1`, but the current
  Tekton tasks request the same repository without a tag, meaning `:latest`.
  Mirroring `:10.1` alone does not satisfy those pulls. Aligning the task references
  and mirror content is separate runtime work; this decision does not establish
  disconnected Tekton support.
- ❌ The list covers only the known, shipped set. A CI guard can fail a release
  that adds a static image without a matching CSV entry — before release, not on
  user deployment — but dynamic dependencies still require manual actualisation,
  and user-added plugins are out of scope entirely.

### Neutral

- ⚖️ This is not a claim of full disconnected support. The
  [Operator authoring guide, section 5.6.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/operators/developing-operators)
  lists replacing hard-coded image references with environment variables and
  using digests as requirements for disconnected support. Those requirements are
  distinct from making images discoverable in the catalog.
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
