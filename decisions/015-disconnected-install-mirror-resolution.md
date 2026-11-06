# ADR: Disconnected Install: Complete Container Image Inventory and Resolution

## Executive Summary / TL;DR

**Decision**: adopt one complete contract for container images in disconnected environments:

> Every container image the operator can inject into a workload it creates for the RHDH profile (`config/profile/rhdh/**`) must be listed in the CSV's `spec.relatedImages` and must be overridable through a matching `RELATED_IMAGE_*` environment variable. No operator-chosen image may require reading operator source or bundle ConfigMaps to discover.

The mechanism is the standard Red Hat operator pattern: `spec.relatedImages` for discovery and mirroring, and `RELATED_IMAGE_*` environment variables for resolution. It is not a new mechanism. It generalizes the override the operator already performs for `backstage`, `postgresql`, and `plugin-installer` (the last only when `OPERATOR_DP_PROCESSING=true`) to every flavour and plugin-dependency image chosen by the RHDH profile. The three core images keep their existing Go code path; moving them into templates is not part of this decision.

**Images covered by this ADR**:

| Image | Required when | `RELATED_IMAGE_*` env var |
|-------|---------------|---------------------------|
| `backstage` (RHDH hub) | Always | `RELATED_IMAGE_backstage` (existing) |
| `postgresql` | Local database is enabled | `RELATED_IMAGE_postgresql` (existing) |
| `lightspeed-core` | Always in 2.1+ — the Intelligent Assistant flavour is `enabledByDefault: true` | `RELATED_IMAGE_lightspeed_core` |
| `okp` | `intelligent-assistant-okp` flavour is enabled (opt-in) | `RELATED_IMAGE_okp` |
| `postgresql` client job | `orchestrator` flavour is enabled (opt-in) | Reuses `RELATED_IMAGE_postgresql` |
| `ubi10-minimal` | Tekton plugin dependency (`ref: tekton`) is enabled; used by orchestrator workflows | `RELATED_IMAGE_ubi_minimal` |
| Tekton git image | Tekton plugin dependency (`ref: tekton`) is enabled; used by orchestrator workflows | `RELATED_IMAGE_tekton_git` |
| `plugin-installer` | `OPERATOR_DP_PROCESSING=true` (dev preview; GA gate) | `RELATED_IMAGE_plugin_installer` (read in Go; not declared on the operator Deployment today) |

**Explicitly out of scope** (with reasons in [Out of scope](#out-of-scope)):

- Plugin catalog index (`CATALOG_INDEX_IMAGE`) — an OCI artifact pulled by skopeo, not the kubelet.
- Dynamic plugin OCI packages — handled by the existing ConfigMap mirror mechanism.
- OSL / Knative operator images — shipped by their own operators.
- Orchestrator runtime downloads from GitHub and `developers.redhat.com` — tracked separately.
- `config/profile/backstage.io` defaults — a bare upstream Backstage profile for development, not the RHDH product profile.

**What this does NOT include**: extending ConfigMap-based mirror resolution to container images. That mechanism remains reserved for OCI plugin packages. Container images use `spec.relatedImages` plus `RELATED_IMAGE_*` env vars only. This keeps one resolution path for kubelet-pulled images and avoids reimplementing IDMS inside the operator.

**Script lifecycle**: no removal date is set. `prepare-restricted-environment.sh` remains supported until the `oc-mirror` workflow is documented for customers, the `rhdh-airgap` E2E mode is migrated, and a Jira tracks removal.

---

## Context

### The air-gap problem in plain terms

When an organisation runs RHDH on a network without internet access (a "disconnected" or "air-gapped" environment), every image the operator needs must first be copied to an internal mirror registry. The workflow has three steps:

1. **Discover** — determine which images are needed.
2. **Mirror** — copy them from the public registry to the internal registry.
3. **Resolve** — make the running operator and its pods pull from the mirror, not the internet.

Today RHDH fails at step 1 for most flavour and plugin-dependency images, and fails at step 3 for all of them.

### The current inventory

The operator does not have two images. It has a set of images that depends on which flavours and plugins are enabled:

| Image | Required when | Defined in | In `spec.relatedImages` | Env override |
|-------|---------------|------------|-------------------------|--------------|
| RHDH hub (`backstage`) | Always | `config/profile/rhdh/patches/deployment-patch.yaml`; `pkg/model/deployment.go` | ✅ | ✅ |
| `postgresql` | Local DB | `config/profile/rhdh/default-config/db-statefulset.yaml`; `pkg/model/db-statefulset.go` | ✅ | ✅ |
| `lightspeed-core` | Always (Intelligent Assistant is enabled by default) | `config/profile/rhdh/default-config/flavours/intelligent-assistant/deployment.yaml` | ❌ | ❌ |
| `okp` | Opt-in `intelligent-assistant-okp` flavour | `config/profile/rhdh/plugin-deps/okp.yaml` | ❌ | ❌ |
| `postgresql` client job | Opt-in `orchestrator` flavour | `config/profile/rhdh/plugin-deps/sonataflow.yaml` | ❌ | ❌ |
| `ubi10-minimal` | Tekton plugin dependency (`ref: tekton`); used by orchestrator workflows | `config/profile/rhdh/plugin-deps/tekton.yaml` (three steps) | ❌ | ❌ |
| Tekton git image | Tekton plugin dependency (`ref: tekton`); used by orchestrator workflows | `config/profile/rhdh/plugin-deps/tekton.yaml` (`BASE_IMAGE` default) | ❌ | ❌ |
| `plugin-installer` | `OPERATOR_DP_PROCESSING=true` (dev preview) | `pkg/model/dynamic-plugins.go`; `Makefile`; `docs/dynamic-plugins.md` — **not in the CSV** | ❌ | ✅ (`os.Getenv`; no default declared) |
| Plugin catalog index | Always (plugin catalog) | `config/profile/rhdh/default-config/deployment.yaml`; `config/profile/rhdh/default-config/catalog.yaml` | ❌ (out of scope — skopeo/OCI path) | `CATALOG_INDEX_IMAGE` |

Two facts matter for the scope decision:

- `config/profile/rhdh/default-config/flavours/intelligent-assistant/metadata.yaml` sets `enabledByDefault: true`, so `lightspeed-core` is part of a default install, not an optional add-on.
- `intelligent-assistant-okp` and `orchestrator` are `enabledByDefault: false`. Their images are only deployed when the flavour is enabled, but they are still chosen by the operator, not by the user. The Tekton images are only deployed when the Tekton plugin dependency is enabled, which is independent of the orchestrator flavour.

### What breaks today

1. **Discovery is broken for flavours and plugin-deps.** Those images live inside bundle ConfigMaps, not in the CSV. `oc-mirror` never sees them. The customer documentation admits this for Lightspeed: the helper script "does not automatically parse Developer Lightspeed for RHDH images from the bundle manifest".
2. **Resolution is broken for the same images.** The operator reads `RELATED_IMAGE_*` only for `backstage`, `postgresql`, and `plugin-installer` (the last only when DP processing is enabled). There is no code path for the Lightspeed sidecar, OKP, or any plugin-dep image. Even if a customer knows the image reference, there is nothing to override.
3. **The operator has no generic mechanism.** Flavours are YAML processed by `ReadDefaultConfig` and `template.ApplyTemplate`. Plugin-deps are YAML processed by `ReadPluginDeps`, which only replaces `{{backstage-name}}` and `{{backstage-ns}}`. There is no per-container Go model for the Lightspeed sidecar or OKP, so an `addToModel()` image override cannot be written as previously proposed.
4. **`plugin-installer` is not discoverable and has no declared default.** The env var exists in `pkg/model/dynamic-plugins.go` and in the `Makefile`, but it is not declared on the operator deployment in the CSV, so `make bundle` never emits a `relatedImages` entry. The `Makefile` substitution for `{{RELATED_IMAGE_plugin_installer}}` is dead code: no manifest contains that placeholder, so `make deploy` and `dist/rhdh/install.yaml` do not set the variable either.
5. **Optional images cannot be skipped automatically.** `oc-mirror` copies every entry in `spec.relatedImages`. `ImageSetConfiguration` can filter packages and channels, but not individual related images. Until [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) lands, listing an image means every `oc-mirror` user mirrors it.

### Why this matters to customers

From [RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417): customers managing multiple disconnected OpenShift clusters use `oc-mirror` as their standard workflow for all Red Hat operators. They expect RHDH to behave the same way. When an operator-chosen image is missing from `spec.relatedImages`, RHDH becomes the exception they must handle manually.

The failure is worse on ROSA with Hosted Control Planes and on vanilla Kubernetes:

- On ROSA/HCP, node-level registry configuration (IDMS/ITMS) is not customer-managed, so the Subscription env override (OLM v0) is the only supported resolution path today. OLM v1 has no equivalent for these env vars yet; see [the OLM v1 gap](#clusters-where-idms-does-not-work-for-example-rosa-with-hosted-control-planes).
- On vanilla Kubernetes there is no OLM and no IDMS at all; env vars on the operator Deployment are the only resolution path.

That is why "discoverable" alone is not enough. Every image must also be **overridable**, because there are platforms where discovery via IDMS does not exist.

### What other Red Hat operators do

The `spec.relatedImages` + `RELATED_IMAGE_*` pattern is standard across the portfolio:

- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml)
- [OADP Operator](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml)
- [Quay Operator](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml)
- [DevWorkspace Operator](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml)
- [Sandboxed Containers Operator](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml)

See the OCP documentation, [Using Operator Lifecycle Manager in disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index#olm-restricted-networks), which states that an Operator must list any related images it may require in the `relatedImages` parameter of its CSV.

---

## Decision

### The contract

RHDH adopts the following rule for every image the operator selects for the RHDH profile:

1. **Discoverable**: the image is listed in the CSV's `spec.relatedImages`, either directly or as the value of a `RELATED_IMAGE_*` env var on the operator deployment (from which `make bundle` generates the entry).
2. **Overridable**: the operator resolves the image through the matching `RELATED_IMAGE_*` env var when it is non-empty, falling back to the upstream default when the env var is unset or empty. Flavour and plugin-dependency images resolve at render time through the template helper; the core images (`backstage`, `postgresql`, `plugin-installer`) keep their existing Go override code. Features that require an explicit value are the exception: `plugin-installer` errors when DP processing is enabled and the env var is empty.
3. **Documented**: the image appears in the operator air-gap reference with its env var name, default value, and the flavour/plugin that requires it.
4. **Guarded**: CI fails if a flavour or plugin-dep under `config/profile/rhdh/**` introduces a literal `image:` or an image-valued Tekton `default:` (such as `BASE_IMAGE`) that is not resolved through the mechanism. CI also fails if a Go-injected `RELATED_IMAGE_*` reference is missing from `deployment-patch.yaml`, or if a generated `relatedImages[]` entry is empty or untagged.

The contract applies to images the operator injects into workloads it creates. It does not apply to images pulled by other operators or by tooling inside a container.

### Images in scope

```yaml
# Source of truth: config/profile/rhdh/patches/deployment-patch.yaml
# (NOT the generated CSV). `make bundle` derives spec.relatedImages from these.
- name: RELATED_IMAGE_postgresql
  value: quay.io/fedora/postgresql-18:latest          # also used by the sonataflow psql job
- name: RELATED_IMAGE_backstage
  value: quay.io/rhdh-community/rhdh:next
- name: RELATED_IMAGE_lightspeed_core
  value: quay.io/lightspeed-core/lightspeed-stack:0.7.3
- name: RELATED_IMAGE_okp
  value: registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:1.3.0-1793303796
- name: RELATED_IMAGE_ubi_minimal
  value: registry.access.redhat.com/ubi10-minimal:10.1
- name: RELATED_IMAGE_tekton_git
  value: cgr.dev/chainguard/git:root-2.39@sha256:7759f87050dd8bacabe61354d75ccd7f864d6b6f8ec42697db7159eccd491139
- name: RELATED_IMAGE_plugin_installer
  value: quay.io/rhdh-community/rhdh-plugin-installer:latest
```

After `make bundle`, the CSV contains the matching entries:

```yaml
relatedImages:
  - image: quay.io/fedora/postgresql-18:latest
    name: postgresql
  - image: quay.io/rhdh-community/rhdh:next
    name: backstage
  - image: quay.io/lightspeed-core/lightspeed-stack:0.7.3
    name: lightspeed-core
  - image: registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:1.3.0-1793303796
    name: okp
  - image: registry.access.redhat.com/ubi10-minimal:10.1
    name: ubi-minimal
  - image: cgr.dev/chainguard/git:root-2.39@sha256:7759f87050dd8bacabe61354d75ccd7f864d6b6f8ec42697db7159eccd491139
    name: tekton-git
  - image: quay.io/rhdh-community/rhdh-plugin-installer:latest
    name: plugin-installer
```

Notes:

- The `backstage` and `postgresql` defaults match `rhdh-operator` `main` at the time of writing. `release-2.1` uses `quay.io/rhdh-community/rhdh:next-2.1` for `backstage`, not `:next`. The remaining entries are proposed by this ADR and do not exist upstream yet. Take the block from the branch being implemented; this ADR records a decision, not an authoritative pin list. ADRs are immutable once merged, so treat this block as a snapshot: refresh values when the operator pins move, and do not copy an old ADR revision into an implementation.
- `operator-sdk generate bundle` derives `spec.relatedImages` from `RELATED_IMAGE_*` env vars found on container specs in the bundle manifests. It does not scan ConfigMap contents, so the env var must be on the operator deployment.
- operator-sdk normalises names: `RELATED_IMAGE_lightspeed_core` becomes `lightspeed-core`, `RELATED_IMAGE_plugin_installer` becomes `plugin-installer`. The underscore/hyphen difference is expected.
- Values must be non-empty. An empty env value produces an empty `relatedImages[].image`, which breaks mirroring. CI must reject it.
- Values must be pinned to a tag or digest. A bare reference such as `registry.access.redhat.com/ubi10-minimal` resolves to `:latest` and drifts between mirror runs; the source-of-truth block above pins `:10.1`. CI must reject untagged entries.
- The upstream/community defaults in the block above that use `:next` or `:latest` (`backstage`, `postgresql`, `plugin-installer`) intentionally stay floating: that is how upstream builds are consumed, and the downstream pipeline replaces them with digest-pinned product images. The pinning rule therefore applies to product values and to the generated CSV/bundle, not to those three upstream defaults.
- `:10.1` is a minor-version stream that Red Hat moves on rebuilds, so it can still drift between mirror runs. Use a dated `10.1-<build>` tag or a digest if run-to-run reproducibility is required; the downstream product image should be digest-pinned either way.
- Use one canonical env var name per image. If the same image appears under two names, operator-sdk emits the image once with an empty name.
- A misspelled or undeclared `RELATED_IMAGE_*` name does not fail fast. The helper falls back to the public default, the pod is scheduled, and the pull then fails with `ImagePullBackOff` in a disconnected cluster. CI must verify that every name passed to `relatedImage` maps to a declared env var. The helper should log a warning when it falls back and `KUBERNETES_SERVICE_HOST` is set (i.e. running in a cluster); do not log during unit tests or `make run`.
- The sonataflow psql job reuses `RELATED_IMAGE_postgresql` rather than introducing a second PostgreSQL entry. It runs `psql` against the same database operand, so the same product image is appropriate. If a future orchestrator version requires a different client version, it gets its own env var.
- The Tekton `ubi10-minimal` reference appears in three step images (`flatten`, `build-manifests`, `build-gitops`); all three resolve through the single `RELATED_IMAGE_ubi_minimal` env var.
- The Tekton git reference is a `Task` parameter default (`BASE_IMAGE`), consumed as `image: $(params.BASE_IMAGE)` rather than a literal `image:` field. The operator still chooses it when the workflow does not override the parameter, so it is covered. The `quay.io/$(params...)` reference that the workflow builds at runtime is not operator-chosen and stays out of scope.
- `plugin-installer` is added now, not at GA. The env var is only consumed when `OPERATOR_DP_PROCESSING=true`, so it is runtime-inert for default installs. It is **not** mirroring-inert: `oc-mirror` copies every `spec.relatedImages` entry, so disconnected users pay the mirror cost even when DP processing is off. Adding it now makes the dev-preview path usable; the extra payload is accepted until OCPSTRAT-3755. When `OPERATOR_DP_PROCESSING=true` and the env var is empty, the operator errors instead of falling back, so the deployment must declare a non-empty default.
- The `lightspeed-rag-init` init-container image mentioned in earlier reviews was removed in RHDH 2.1 and is not part of this inventory.

### Resolution mechanism

The operator must resolve every **flavour and plugin-dependency** image through a template helper at render time. The three core images (`backstage`, `postgresql`, `plugin-installer`) keep their existing Go overrides; this ADR does not move them into templates.

The helper reads the `RELATED_IMAGE_*` env var when it is non-empty and otherwise returns the upstream default baked into the manifest. The fallback is required for rendering paths that do not run from the operator Deployment: `make run` sets only `OPERATOR_DP_PROCESSING` and `RELATED_IMAGE_plugin_installer`, unit and integration tests construct the model without a Deployment, and custom installs may omit an env var. By contrast, `make deploy` and `dist/rhdh/install.yaml` inherit every variable from `deployment-patch.yaml`, and the Helm chart deploys RHDH directly without the operator, so none of those paths rely on the fallback. An empty image would break any path that does.

A raw `{{env.RELATED_IMAGE_*}}` placeholder is not sufficient on its own. It has no fallback, so any render without the env var (local runs, tests, custom installs) would produce an empty image, and the plugin-deps loader does not run the template engine at all today. The helper plus the loader change below solves both problems.

```yaml
# Flavour: config/profile/rhdh/default-config/flavours/intelligent-assistant/deployment.yaml
- name: lightspeed-core
  image: '{{ relatedImage "lightspeed-core" "quay.io/lightspeed-core/lightspeed-stack:0.7.3" }}'
```

```yaml
# Plugin-deps: config/profile/rhdh/plugin-deps/sonataflow.yaml
image: '{{ relatedImage "postgresql" "quay.io/fedora/postgresql-18:latest" }}'
```

```yaml
# Plugin-deps: config/profile/rhdh/plugin-deps/tekton.yaml
- name: BASE_IMAGE
  default: '{{ relatedImage "tekton-git" "cgr.dev/chainguard/git:root-2.39@sha256:7759f87050dd8bacabe61354d75ccd7f864d6b6f8ec42697db7159eccd491139" }}'
# ...
- name: flatten
  image: '{{ relatedImage "ubi-minimal" "registry.access.redhat.com/ubi10-minimal:10.1" }}'
```

Operator changes:

```go
// pkg/template/template.go
import (
    "os"
    "strings"
    "text/template"
)

const relatedImageEnvPrefix = "RELATED_IMAGE_"

// relatedImage returns the RELATED_IMAGE_* override when it is non-empty,
// otherwise the fallback baked into the manifest. The empty check matches
// pkg/model/deployment.go and pkg/model/db-statefulset.go: an explicitly
// empty env var falls back instead of producing an empty image.
func relatedImage(name, fallback string) string {
    env := relatedImageEnvPrefix + strings.ReplaceAll(name, "-", "_")
    if v := os.Getenv(env); v != "" {
        return v
    }
    return fallback
}
```

The helper must be registered before parsing. `text/template` resolves function names at parse time, so a missing `Funcs` entry is a parse error, not a silent fall-through to the literal string:

```go
tmpl, err := template.New("config").
    Funcs(template.FuncMap{"relatedImage": relatedImage}).
    Parse(string(content))
```

Implementation rules:

- **Template-time, not post-render.** A generic "walk pod specs after rendering" pass would miss Tekton `Task` steps (`spec.steps[].image`), which are not pod specs. Template-time covers Deployments, Jobs, and Tekton Tasks uniformly.
- **Register the helper explicitly.** `template.New("config")` currently has no `Funcs` call. Add `.Funcs(template.FuncMap{"relatedImage": relatedImage})` before `.Parse`; without it every new placeholder fails at parse time.
- **One source of truth.** Read `os.Getenv` in the helper instead of adding a `RelatedImages` map to `TemplateData`. A map duplicates the Deployment env, can go stale, and forces every construction path to populate it. Tests can use `t.Setenv`.
- **Extend the template guard.** `ApplyTemplate` has two checks: it returns unless it sees a `.Rhdh.` or `{{if ...}}` pattern, then returns again unless the content contains `.Rhdh.`. Replace both with `hasRhdh := strings.Contains(contentStr, ".Rhdh.")` and `hasRelatedImage := strings.Contains(contentStr, "relatedImage")`, and parse when either is true. Keeping the second `.Rhdh.` check would make `relatedImage`-only content a silent no-op. Do not parse arbitrary `{{...}}` content: plugin-deps still contain `{{backstage-name}}` / `{{backstage-ns}}` until the legacy replacements run.
- **Migrate plugin-deps to the template engine.** `ReadPluginDeps` calls `strings.ReplaceAll` for `{{backstage-name}}` and `{{backstage-ns}}` and never calls `ApplyTemplate`. Do the legacy replacements first (Go templates would treat `{{backstage-name}}` as an undefined function), then call `ApplyTemplate`. Alternatively, migrate those two placeholders to `{{.Rhdh.Name}}` and `{{.Rhdh.Namespace}}` in the same change. Build `TemplateData` from the existing `bsName`, `bsNamespace`, and `platformExt` arguments rather than calling `NewTemplateData`, which also requires `Platform` and `ExternalConfig` objects that this path does not have.
- **No CRD or API change.** This is a rendering and CSV change only.

### Optionality and `oc-mirror`

`spec.relatedImages` has no mandatory/optional classification today. That creates an unavoidable trade-off:

- **`oc-mirror` users** mirror every related image, including opt-in flavours they do not use. OKP is 10+ GB; the Tekton and sonataflow images add more. `ImageSetConfiguration` can filter packages and channels but cannot exclude an individual `relatedImages` entry. `additionalImages` only adds images; it does not deselect the ones the CSV already lists.
- **Manual-mirroring users** (skopeo, crane, or an internal replication tool) consult the inventory and copy only the images for the flavours and plugins they enable. They can copy the rest later; no `ImageSetConfiguration` is involved. `additionalImages` is the `oc-mirror` escape hatch for images outside `spec.relatedImages` (for example third-party plugin images), not an opt-out for CSV entries.

This ADR chooses correctness over payload size: list every operator-deployable image now, document the cost, and use [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) as the exit. A partial list would leave ROSA/HCP and vanilla Kubernetes users without a discoverable override for opt-in flavours — exactly the class of bug this ADR exists to remove.

### Out of scope

| Item | Why it is out of scope | Where it is handled |
|------|------------------------|---------------------|
| Plugin catalog index (`CATALOG_INDEX_IMAGE`) | An OCI artifact pulled by skopeo inside the init container, not by the kubelet; IDMS does not apply | The plugin mirror path, `CATALOG_INDEX_IMAGE`, and `extraEnvs` |
| Dynamic plugin OCI packages | Pulled by skopeo inside the install-dynamic-plugins container | The existing ConfigMap mirror mechanism ([RHIDP-15003](https://redhat.atlassian.net/browse/RHIDP-15003)); still dev preview |
| OSL / Knative operator images | Shipped and managed by their own operators | Each operator's own `spec.relatedImages` |
| Orchestrator runtime downloads | `tekton.yaml` runs `curl` against `raw.githubusercontent.com` and `developers.redhat.com` at task runtime | Follow-up Jira; see [Follow-ups](#follow-ups) |
| `config/profile/backstage.io` defaults | A bare Backstage profile for development and upstream testing, not the RHDH product profile. It hardcodes `ghcr.io/backstage/backstage` and has no `deployment-patch.yaml`, so there is no `RELATED_IMAGE_backstage` for its bundle | Profile maintainers; out of the RHDH disconnected-install contract |

### How this works on each platform

#### OpenShift (standard — IDMS works)

1. **Discover**: `oc-mirror` reads `spec.relatedImages` from the CSV.
2. **Mirror**: `oc-mirror` copies all listed images to the customer's mirror registry.
3. **Resolve**: `oc-mirror` generates `ImageDigestMirrorSet` / `ImageTagMirrorSet` resources (or `ImageContentSourcePolicy` on older OCP). Apply the generated manifests to the cluster, then install RHDH. CRI-O transparently redirects image pulls. The operator reads the `RELATED_IMAGE_*` env vars and writes those references into the objects it creates; IDMS/ITMS rewrite them at pull time.

The workflow is therefore: run `oc-mirror`, apply the generated IDMS/ITMS (or ICSP), then install. Applying the mirror configuration is a separate step from copying the images.

#### Clusters where IDMS does not work (for example ROSA with Hosted Control Planes)

On ROSA/HCP, node-level registry configuration is not customer-managed, so IDMS/ITMS cannot be applied. Users still use `oc-mirror` to copy images, then override the operator's env vars on the Subscription (OLM v0). OLM v1 has no equivalent today; see below.

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
        value: mirror.company.com/rhdh/rhdh-hub-rhel9@sha256:<digest>
      - name: RELATED_IMAGE_postgresql
        value: mirror.company.com/rhel10/postgresql-18@sha256:<digest>
      - name: RELATED_IMAGE_lightspeed_core
        value: mirror.company.com/lightspeed-core/lightspeed-stack-rhel9@sha256:<digest>
      - name: RELATED_IMAGE_okp
        value: mirror.company.com/offline-knowledge-portal/rhokp-rhel9@sha256:<digest>
      - name: RELATED_IMAGE_ubi_minimal
        value: mirror.company.com/ubi10/ubi-minimal@sha256:<digest>
      - name: RELATED_IMAGE_tekton_git
        value: mirror.company.com/tekton/git@sha256:<digest>
      - name: RELATED_IMAGE_plugin_installer
        value: mirror.company.com/rhdh/rhdh-plugin-installer@sha256:<digest>
```

For OLM v0, `Subscription.spec.config.env` is the supported override (verified).

For OLM v1, the shape is different: `ClusterExtension.spec.config` is a bundle-specific, schema-validated inline configuration (`configType: Inline` plus an `inline` object merged into the rendered manifests), **not** an `env` list. The RHDH bundle does not currently expose a configuration schema for `RELATED_IMAGE_*`, so an OLM v1 cluster cannot use `spec.config` to override these env vars today. On standard OpenShift this is masked by IDMS; on ROSA/HCP with OLM v1 it is a real gap. The implementation must either add a bundle configuration schema that exposes the image overrides or document a supported post-install override, and that must be resolved before claiming full ROSA/HCP coverage on OLM v1.

This path only works for images the operator actually reads env vars for — which is why the contract covers every image, not only the default ones.

#### Vanilla Kubernetes (no OLM, no IDMS)

1. **Discover**: extract the CSV from the shipped bundle image, then read `spec.relatedImages`:

   ```bash
   BUNDLE_IMAGE="registry.redhat.io/rhdh/rhdh-operator-bundle:${RHDH_VERSION}"
   CONTAINER_ID=$(podman create "${BUNDLE_IMAGE}")
   podman cp "$CONTAINER_ID:/manifests/rhdh-operator.clusterserviceversion.yaml" ./rhdh-operator.clusterserviceversion.yaml
   podman rm "$CONTAINER_ID"

   # Keep the name so users know which RELATED_IMAGE_* env var to set.
   yq '.spec.relatedImages[]' rhdh-operator.clusterserviceversion.yaml
   ```

2. **Mirror**: copy the images with the organisation's tooling (skopeo, crane, or similar). This ADR does not prescribe a tool.
3. **Resolve**: set `RELATED_IMAGE_*` env vars on the operator Deployment, pointing at the mirrored images. The env var name is `RELATED_IMAGE_` plus the related image name with `-` replaced by `_` (`lightspeed-core` → `RELATED_IMAGE_lightspeed_core`).

---

## Implementation

### Operator changes

| Area | Files | Change | Validation |
|------|-------|--------|------------|
| Env var source | `config/profile/rhdh/patches/deployment-patch.yaml` | Add every `RELATED_IMAGE_*` env var from the inventory with a non-empty default: upstream floating tags for upstream builds, which the downstream pipeline replaces with digest-pinned product images. Include `RELATED_IMAGE_plugin_installer`, which today is declared only in the `Makefile` and not in `deployment-patch.yaml`. | `make bundle`; inspect `spec.relatedImages` for missing, empty, or untagged product entries |
| Intelligent Assistant flavour | `config/profile/rhdh/default-config/flavours/intelligent-assistant/deployment.yaml` | Replace the hardcoded `lightspeed-core` image with the `relatedImage` helper | Unit test: env set → override; env unset → fallback |
| Plugin-deps | `config/profile/rhdh/plugin-deps/okp.yaml`, `sonataflow.yaml`, `tekton.yaml` | Replace hardcoded images with the helper, including the Tekton `BASE_IMAGE` default | Unit tests for each object type |
| Template engine | `pkg/template/template.go` | Add the `relatedImage` helper, register it in a `FuncMap` before `Parse`, and extend the detection guard to parse content containing `relatedImage` | `pkg/template/template_test.go` |
| Plugin-deps loader | `pkg/model/plugin_deps.go`, `GetPluginDeps` | Pass `TemplateData` through and call `ApplyTemplate` after the legacy replacements | `pkg/model` unit tests |
| Bundle generation | `Makefile` / `make bundle` | No manual `relatedImages` editing; verify generation from env vars. Remove the `{{RELATED_IMAGE_plugin_installer}}` `sed` substitutions or point them at a real template: no manifest contains that placeholder today, so `make deploy` and `dist/rhdh/install.yaml` silently omit the value. | Assert all entries present and no empty `image` |
| CI guard | `.github/workflows`, `hack/` | Fail on (a) a literal `image:` under `config/profile/rhdh/**` that is neither on the short Go-handled core allowlist nor a `$(params.*)` reference; (b) an image-valued Tekton `default:` (such as `BASE_IMAGE`) that does not use the helper; (c) a `relatedImage` name with no matching declared env var; (d) a Go-injected `RELATED_IMAGE_*` reference in `pkg/model/deployment.go`, `db-statefulset.go`, `dynamic-plugins.go`, or the `Makefile` that is missing from `deployment-patch.yaml`; (e) an empty or untagged `relatedImages[].image` in the generated CSV | PR check |
| E2E | `tests/e2e/` | Air-gap scenario with env overrides; replace the dependency on the deprecated script | Passes without external registry access |
| OLM v1 override path | Bundle CSV / OLM v1 documentation | Define a supported way to set `RELATED_IMAGE_*` on a `ClusterExtension` (bundle configuration schema or documented post-install override) | Verified on an OLM v1 cluster |

### Downstream changes

| Script | Current behaviour | Required change |
|--------|-------------------|-----------------|
| `build/scripts/intelligent-assistant/replaceUpstreamImages.sh` | Rewrites the Lightspeed flavour ConfigMap and the plugin-deps ConfigMap. **Does not touch the CSV.** | Also rewrite the CSV `RELATED_IMAGE_*` values and the generated `spec.relatedImages` entries. Add the Tekton and sonataflow images, which are now in scope. |
| `build/ci/sync-midstream.sh` | `bundle_product_images_stale()` checks PostgreSQL (CSV/default ConfigMap), Lightspeed (flavour ConfigMap), and OKP (plugin-deps ConfigMap). There is a TODO to compare OKP in the CSV. | Move/extend the checks to the CSV env vars and `spec.relatedImages`; remove the TODO; add the new images. |
| `checkImage()` in `sync-midstream.sh` | Maps only `registry.redhat.io/rhdh` ↔ `quay.io/rhdh` and relies on upstream `.Labels.version`/`.Labels.release` | Add explicit mappings, for example `quay.io/lightspeed-core/lightspeed-stack` → `registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9`. The generic loop cannot infer the `-rhel9` product name. |
| `build/scripts/checkImagesInFBC.sh` | Reads `.relatedImages[].image` from the catalog | No change; new entries flow through automatically once the CSV is correct. |

Ordering: pin the env var values before `make bundle` where possible. If the downstream pipeline rewrites the bundle after generation, rewrite both the env vars and `spec.relatedImages` so they stay consistent.

### Conforma and trusted registries

Adding images to `spec.relatedImages` makes them subject to Conforma validation. Downstream product bundles must reference `registry.redhat.io` images, not upstream registries:

- `quay.io/lightspeed-core/lightspeed-stack` must map to `registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9`.
- `quay.io/fedora/postgresql-18` must map to the product PostgreSQL image.
- `registry.access.redhat.com/ubi10-minimal` should map to its `registry.redhat.io` equivalent.
- `cgr.dev/chainguard/git` is a third-party registry and may fail trusted-registry validation. This needs a product decision before the Tekton images are shipped in a product bundle: replace it with a Red Hat-hosted git image, or record an approved exception. The upstream default remains until that decision is made.

### Documentation changes

| Document | Current state | Change |
|----------|---------------|--------|
| Operator air-gap installation | Describes only the helper script | Document the `oc-mirror` + `spec.relatedImages` path (including applying the generated IDMS/ITMS), the Subscription env override path (OLM v0), and the vanilla Kubernetes path. Document the OLM v1 gap and link the follow-up; do not describe a `ClusterExtension` env override that does not exist. Add the deprecation notice only when the replacement is ready. |
| Intelligent Assistant air-gap | Says images must be mirrored manually | Remove the manual extraction note. Document that OKP is optional for manual-mirroring users but is mirrored automatically by `oc-mirror` until OCPSTRAT-3755. |
| Orchestrator air-gap | OpenShift with `oc-mirror` | Document the additional images: `ubi10-minimal` and Tekton git (pulled in by the Tekton plugin dependency, which orchestrator workflows use) and the sonataflow psql job. Document the runtime download limitation. Do not claim that orchestrator uses no additional container images. |
| `.rhdh/docs/airgap.adoc` | Lists only RHDH and PostgreSQL | Add the full inventory, the optionality classification, and the env override examples. |
| `docs/dynamic-plugins.md` | Plugin-installer is documented as a manual env var | Document that `RELATED_IMAGE_plugin_installer` is now a first-class related image, required whenever `OPERATOR_DP_PROCESSING=true`. Fix the stale `deployment-patch.yaml#L31-L32` link for `CATALOG_INDEX_IMAGE`. |
| Contributor docs (`docs/profiles.md` or new `docs/images.md`) | No rule for flavour/plugin-deps authors | Add the image contract, the `relatedImage` helper usage, the env var naming rule, and the CI check. This is required, not optional: without it the next flavour will reintroduce a hardcoded image. |
| Helm chart (`redhat-developer/rhdh-chart`) | `charts/rhdh/values.yaml` in the separate `redhat-developer/rhdh-chart` repository, not in `rhdh-operator`. | Link the correct file and repository. Note that Helm keeps its own image inventory and has no `spec.relatedImages` equivalent. Keep the Lightspeed and OKP pins in sync with the operator. They are currently in sync (Lightspeed `0.7.3`, OKP `1.3.0-1793303796`), but they have drifted before, so add a check rather than relying on manual review. |

### Script lifecycle

`prepare-restricted-environment.sh` remains supported. Removal requires all of the following, tracked by a Jira:

1. Customer documentation covers the `oc-mirror` and env-override workflow for OpenShift, ROSA/HCP, and vanilla Kubernetes.
2. The `rhdh-airgap` E2E mode no longer depends on the script.
3. A deprecation notice is added to the script header and `.rhdh/docs/airgap.adoc`.

Until then, no removal date is set. This avoids removing the only end-to-end disconnected test path before a replacement exists.

For accuracy: the script reads `image:` values and `RELATED_IMAGE_*` env values **from the CSV**. It does not read `.spec.relatedImages` directly, and it does not read images embedded in bundle ConfigMaps. Promoting every image to a CSV env var is therefore what makes the script and the `rhdh-airgap` E2E mode see them.

---

## Alternatives Considered

### Alternative 1: Extend ConfigMap mirror resolution to container images

**Approach**: Reuse the existing plugin-registry mirror ConfigMap mechanism to rewrite container image references during reconciliation.

This was the approach in earlier revisions of this ADR.

**Rejected because**:

1. **Reinvents IDMS**: the ConfigMap approach duplicates what IDMS already does, with different semantics.
2. **Unnecessary**: `RELATED_IMAGE_*` env vars plus `spec.relatedImages` are the standard mechanism and cover every platform that has a supported override path (OpenShift via IDMS, OLM v0 via Subscription config, vanilla Kubernetes via Deployment env vars). The one remaining gap, OLM v1, should be closed in that mechanism rather than by adding a second one.
3. **Premature**: the ConfigMap mechanism for plugins is still dev preview ([RHIDP-15003](https://redhat.atlassian.net/browse/RHIDP-15003)).
4. **Two mechanisms**: one for plugin OCI packages and one for container images is correct; adding a second container-image mechanism is not.

### Alternative 2: ConfigMap mirror resolution only (no `spec.relatedImages`)

**Approach**: Rely solely on ConfigMap-based runtime resolution and do not add images to `spec.relatedImages`.

**Rejected because**:

1. **Breaks `oc-mirror`**: customers expect discovery from `spec.relatedImages` ([RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417)).
2. **Breaks Conforma validation**: downstream pipelines cannot verify images that are not listed.
3. **Non-standard**: every other Red Hat operator uses `spec.relatedImages`.

### Alternative 3: Document-only fixes

**Approach**: Leave the code unchanged and add manual extraction steps to the documentation.

**Rejected because**:

- It does not scale with flavours and plugin-deps.
- It guarantees recurring documentation gaps as images change.
- It contradicts the operator's purpose (automation).
- It does not address `oc-mirror` or Conforma compliance.

### Alternative 4: Post-render image substitution

**Approach**: After rendering all objects, walk the object graph and replace sentinel image references with env var values.

**Rejected because**:

- Tekton `Task` steps (`spec.steps[].image`) are not pod specs, so a generic pod-spec walker misses them.
- Template-time substitution covers Deployments, Jobs, and Tekton Tasks with one mechanism.
- The operator already has a template pipeline for default config; extending it is smaller than adding a second post-processing pass.

### Alternative 5: Partial `relatedImages` list (default-required images only)

**Approach**: List only images required by a default install (`backstage`, `postgresql`, `lightspeed-core`) and document opt-in images, including `plugin-installer` and the Tekton/sonataflow images, as `additionalImages` entries in the customer's `ImageSetConfiguration`.

**Rejected for now because**:

- It leaves ROSA/HCP and vanilla Kubernetes users to discover opt-in images themselves.
- It reintroduces the exact failure this ADR is fixing, just for a smaller set of flavours.
- It is the right model once [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) provides mandatory/optional classification. Revisit then.

---

## Consequences

### Positive

- ✅ **Standard Red Hat operator compliance**: `spec.relatedImages` + `RELATED_IMAGE_*` follows the portfolio pattern.
- ✅ **`oc-mirror` can discover every image**: every operator-deployable image is listed in `spec.relatedImages`.
- ✅ **Override works on the main paths**: OpenShift via IDMS, ROSA/HCP via Subscription env vars on OLM v0, and vanilla Kubernetes via Deployment env vars. The OLM v1 path is tracked as a follow-up.
- ✅ **Conforma validation**: downstream pipelines can verify every related image.
- ✅ **One mechanism for container images**: no parallel ConfigMap resolution path.
- ✅ **Future-proof**: the template helper and CI guard cover new flavours and plugin-deps, not just today's list.
- ✅ **Backward compatible**: existing `backstage`, `postgresql`, and `plugin-installer` handling is unchanged; new flavour and plugin-dependency placeholders fall back to the upstream default when no env var is set.

### Negative

- ❌ **Mirror payload grows**: `oc-mirror` users mirror OKP (10+ GB) and the Tekton/sonataflow images even when they do not enable the corresponding flavour or plugin. This lasts until OCPSTRAT-3755.
- ❌ **`plugin-installer` adds mirror cost before GA**: it is runtime-inert when `OPERATOR_DP_PROCESSING=false`, but `oc-mirror` still copies its `relatedImages` entry for every disconnected user.
- ❌ **Optionality is documentation-only**: manual-mirroring users can skip opt-in images, but `oc-mirror` users cannot.
- ❌ **OLM v1 override is undefined today**: `ClusterExtension.spec.config` is a bundle-specific schema and the RHDH bundle does not expose one, so OLM v1 clusters depend on IDMS or a post-install patch until the follow-up lands.
- ❌ **Third-party registry risk**: `cgr.dev/chainguard/git` and upstream `quay.io/fedora/postgresql-18` may fail Conforma trusted-registry validation. The operator currently ships `ubi10-minimal` untagged (resolving to `:latest`); this ADR pins `:10.1` in the proposed env var, and CI must reject untagged values.
- ❌ **Template failure mode**: a malformed placeholder can break reconciliation. A misspelled or undeclared env var is worse: the helper silently falls back to the public image and the failure surfaces only at pull time as `ImagePullBackOff`. Unit tests and the CI guard are required.
- ❌ **Downstream work**: `replaceUpstreamImages.sh` and `sync-midstream.sh` need explicit changes; the generic digest loop is not sufficient.
- ❌ **E2E dependency**: the `rhdh-airgap` mode still depends on the script until it is migrated.
- ❌ **No removal date for the script**: keeping it avoids breaking E2E, but leaves a legacy path in the repository longer.

### Neutral

- ⚖️ **Plugin OCI packages remain separate**: the ConfigMap mechanism is unaffected; plugins and container images have different pull paths.
- ⚖️ **No CRD or API change**: this is a CSV and rendering change only.
- ⚖️ **Helm is a separate inventory**: the chart keeps its own values and has no `spec.relatedImages` equivalent; the pins must be kept in sync manually.

---

## Follow-ups

| Item | Owner | Why it is not in this ADR |
|------|-------|---------------------------|
| [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) — mandatory/optional `relatedImages` | OCP | Platform capability; this ADR cannot implement it. Revisit the partial-list model when it lands. |
| Tekton git image trust | RHDH product / Conforma | Requires a product decision on a Red Hat-hosted replacement or an approved exception. |
| Orchestrator runtime downloads (`curl` from GitHub / `developers.redhat.com`) | Orchestrator team | Separate from image mirroring; needs a workflow-builder change or a documented limitation. |
| `prepare-restricted-environment.sh` removal | RHDH Install | Requires docs, E2E migration, and a Jira. |
| `plugin-installer` GA | RHDH Operator | The image and env var are added now; the GA gate is when `OPERATOR_DP_PROCESSING` becomes the default path. |
| OLM v1 `RELATED_IMAGE_*` override | RHDH Operator | `ClusterExtension.spec.config` is bundle-schema-specific, and the RHDH bundle does not currently expose a schema. Required for ROSA/HCP on OLM v1. |
| CI guard and contributor docs | RHDH Operator | Part of the implementation, but tracked separately so it is not lost. |

---

## References

### Operator source code

- [`spec.relatedImages` in the CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml)
- [`RELATED_IMAGE_*` env vars in the CSV](https://github.com/redhat-developer/rhdh-operator/blob/main/bundle/rhdh/manifests/backstage-operator.clusterserviceversion.yaml)
- [`config/profile/rhdh/patches/deployment-patch.yaml`](https://github.com/redhat-developer/rhdh-operator/blob/main/config/profile/rhdh/patches/deployment-patch.yaml) — source of truth for operator env vars on `main`
- [`config/profile/rhdh/patches/deployment-patch.yaml` on `release-2.1`](https://github.com/redhat-developer/rhdh-operator/blob/release-2.1/config/profile/rhdh/patches/deployment-patch.yaml) — `RELATED_IMAGE_backstage` is `:next-2.1` on this branch
- [`pkg/model/deployment.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/deployment.go) — `RELATED_IMAGE_backstage`
- [`pkg/model/db-statefulset.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/db-statefulset.go) — `RELATED_IMAGE_postgresql`
- [`pkg/model/dynamic-plugins.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/dynamic-plugins.go) — `RELATED_IMAGE_plugin_installer`
- [`pkg/model/plugin_deps.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/plugin_deps.go) — plugin-deps loader; currently only replaces `{{backstage-name}}` / `{{backstage-ns}}`
- [`pkg/template/template.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/template/template.go) — template data and `ApplyTemplate`
- [`pkg/model/default-config.go`](https://github.com/redhat-developer/rhdh-operator/blob/main/pkg/model/default-config.go) — flavour ConfigMap rendering
- [`config/profile/rhdh/default-config/flavours/`](https://github.com/redhat-developer/rhdh-operator/tree/main/config/profile/rhdh/default-config/flavours) — flavour manifests
- [`config/profile/rhdh/plugin-deps/`](https://github.com/redhat-developer/rhdh-operator/tree/main/config/profile/rhdh/plugin-deps) — plugin dependency manifests
- [`docs/dynamic-plugins.md`](https://github.com/redhat-developer/rhdh-operator/blob/main/docs/dynamic-plugins.md) — operator DP processing mode
- [`docs/profiles.md`](https://github.com/redhat-developer/rhdh-operator/blob/main/docs/profiles.md) — flavour documentation
- [`.rhdh/docs/airgap.adoc`](https://github.com/redhat-developer/rhdh-operator/blob/main/.rhdh/docs/airgap.adoc) — operator air-gap reference
- [`prepare-restricted-environment.sh`](https://github.com/redhat-developer/rhdh-operator/blob/main/.rhdh/scripts/prepare-restricted-environment.sh) — current helper script

### Downstream automation

These scripts live in the **internal downstream dist-git repository**, `gitlab.cee.redhat.com/rhidp/rhdh`, not in the public [`redhat-developer/rhdh`](https://github.com/redhat-developer/rhdh) GitHub repository (whose `build/` directory contains only containerfiles):

- `build/scripts/intelligent-assistant/replaceUpstreamImages.sh`
- `build/ci/sync-midstream.sh`
- `build/scripts/checkImagesInFBC.sh`

### operator-sdk

- [`relatedimages.go`](https://github.com/operator-framework/operator-sdk/blob/master/internal/cmd/operator-sdk/generate/internal/relatedimages.go) — how `RELATED_IMAGE_*` env vars become `spec.relatedImages`

### Helm chart

The Helm chart is maintained in a separate repository and keeps its own image inventory:

- [`charts/rhdh/values.yaml`](https://github.com/redhat-developer/rhdh-chart/blob/main/charts/rhdh/values.yaml) — Lightspeed and OKP image values

### Other Red Hat operators

- [OpenTelemetry Operator CSV](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml)
- [OADP Operator CSV](https://github.com/openshift/oadp-operator/blob/oadp-dev/bundle/manifests/oadp-operator.clusterserviceversion.yaml)
- [Quay Operator CSV](https://github.com/quay/quay-operator/blob/master/bundle/manifests/quay-operator.clusterserviceversion.yaml)
- [DevWorkspace Operator CSV](https://github.com/devfile/devworkspace-operator/blob/main/deploy/bundle/manifests/devworkspace-operator.clusterserviceversion.yaml)
- [Sandboxed Containers Operator CSV](https://github.com/openshift/sandboxed-containers-operator/blob/devel/bundle/manifests/sandboxed-containers-operator.clusterserviceversion.yaml)

### Jira / upstream trackers

- [RHDHPLAN-1887](https://redhat.atlassian.net/browse/RHDHPLAN-1887) — centralize the air-gap image inventory
- [RHDHSUPP-417](https://redhat.atlassian.net/browse/RHDHSUPP-417) — customer expectation: `oc-mirror` should work for RHDH like other Red Hat operators
- [RHIDP-15003](https://redhat.atlassian.net/browse/RHIDP-15003) — ConfigMap-based mirror resolution for dynamic plugins (dev preview)
- [OCPSTRAT-3755](https://redhat.atlassian.net/browse/OCPSTRAT-3755) — mandatory/optional classification for `spec.relatedImages`

### OpenShift documentation

- [Disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index)
- [OLM in disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/disconnected_environments/index#olm-restricted-networks) — defines the `spec.relatedImages` requirement

### RHDH product documentation

- [Air-gapped Operator installation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_in_an_air-gapped_environment/index#install-rhdh-in-an-air-gapped-environment-with-the-operator_installing-rhdh-in-an-air-gapped-environment)
- [LightSpeed air-gap configuration](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/interacting_with_red_hat_developer_lightspeed_for_red_hat_developer_hub/configure-to-initialize-the-ai-assistant_interacting-with-developer-lightspeed-for-rhdh#mirror-images-for-air-gapped-environments_configure-to-initialize-the-ai-assistant)
- [Orchestrator air-gap installation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/orchestrator_in_red_hat_developer_hub/install-orchestrator-plugin-in-an-air-gapped-environment-with-the-operator_orchestrator-in-rhdh)
