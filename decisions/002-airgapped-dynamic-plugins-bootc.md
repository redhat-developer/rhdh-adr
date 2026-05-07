# ADR: Air-Gapped Dynamic Plugin Support for Bootc Deployments

## Context

**Problem**: RHDH dynamic plugins cannot be installed on a fully disconnected (air-gapped) bootc appliance. The current plugin installation pipeline requires network access at two points during runtime startup, and a bootc VM deployed from a QCOW2/ISO image has no network connectivity and no mirror registry available.

The RHDH plugin installation system relies on two runtime network calls:

1. **Catalog index pull**: The `install-dynamic-plugins.py` script reads the `CATALOG_INDEX_IMAGE` environment variable and uses `skopeo copy` to pull the catalog index OCI image (e.g., `quay.io/rhdh/plugin-catalog-index:1.9`). It extracts `dynamic-plugins.default.yaml` and `catalog-entities/` from this image.

2. **Plugin artifact pull**: For each enabled plugin listed in `dynamic-plugins.default.yaml`, the script's `OciDownloader` class uses `skopeo copy` to pull the plugin OCI artifact (e.g., `oci://ghcr.io/redhat-developer/rhdh-plugins/backstage-community-plugin-quay:1.8`) and extracts the plugin tarball.

Both of these calls fail in a disconnected environment. The existing `mirror-plugins.sh` script solves this for Helm chart and Operator deployments by mirroring plugins to a mirror registry (`--to-registry`) or exporting to a directory for later import (`--to-dir` + `--from-dir`). However, both modes assume a registry exists on the destination network. A bootc appliance has no registry — everything must be consumed directly from the local filesystem.

The RHDH bootc base image is intentionally minimal: it ships with `plugins: []`, no `dynamic-plugins.default.yaml`, no default auth providers, and no default catalog rules. Consumers layer their plugins on top. This design is correct, but consumers who want the default plugin set (the ~34 community plugins bundled in the catalog index) have no automated path to get them onto disk for a disconnected deployment.

**Who is impacted**:
- Teams building air-gapped bootc appliances that consume the RHDH bootc base image (e.g., the Ansible Automation Platform team)
- Platform teams deploying RHDH on disconnected VMs or edge devices
- Any consumer who wants the default plugin set in a disconnected bootc environment

**Constraints**:
- The bootc base image must remain minimal — no default plugins baked in
- No mirror registry is available on the disconnected bootc appliance
- `install-dynamic-plugins.py` currently only supports OCI references via `skopeo`
- `mirror-plugins.sh` currently only outputs to registries or OCI directory format (designed for registry reimport)
- The solution must work within the existing bootc startup chain: `systemd` -> Quadlet -> `wait-for-plugins-and-start.sh` -> `prepare-and-install-dynamic-plugins.sh` -> `install-dynamic-plugins.py`
- Changes to `install-dynamic-plugins.py` are upstream (rhdh repo) and affect all deployment methods, not just bootc
- This is scoped for RHDH 2.1+ (past feature phase for 1.x)

## Decision

Enable air-gapped dynamic plugin support for bootc deployments by extending the existing `install-dynamic-plugins.py` script and `mirror-plugins.sh` tool to support local filesystem paths via the `file://` protocol. The bootc base image itself requires no changes.

**Implementation approach**:
- **Extend `install-dynamic-plugins.py`** (rhdh repo) to support `file://` protocol for both the `CATALOG_INDEX_IMAGE` environment variable and individual plugin package references, enabling the script to read the catalog index and plugin artifacts directly from the local filesystem instead of pulling them via `skopeo`
- **Extend `mirror-plugins.sh`** (rhdh-operator repo) with a new `--to-local-plugins` output mode that extracts plugin tarballs to a ready-to-use directory layout and rewrites all `oci://` references to `file://` local paths, rather than mirroring to a registry or keeping plugins in OCI image format
- **Consolidate output to a single directory** (e.g., `/etc/rhdh/extensions/`) containing the rewritten `dynamic-plugins.default.yaml`, `catalog-entities/`, and extracted `plugins/` subdirectories, so consumers only need one `COPY` and one Quadlet volume mount
- **Maintain the minimal bootc base image** — the base ships no default plugins, no catalog index, and no changes are needed to any bootc scripts; consumers layer plugins at their image build time using the extended tooling

**Consumer workflow**:
```bash
# Phase 1: On a connected workstation
./mirror-plugins.sh \
  --plugin-index oci://quay.io/rhdh/plugin-catalog-index:1.9 \
  --to-local-plugins /output/rhdh-extensions/

# Phase 2: Consumer Containerfile
FROM registry.redhat.io/rhdh/rhdh-rhel9-bootc:2.1
COPY output/rhdh-extensions/ /etc/rhdh/extensions/
```

## Design Decisions

### Decision 1: Extend Existing Tools Instead of Creating a New Tool

**Chosen:** Extend `install-dynamic-plugins.py` and `mirror-plugins.sh` with `file://` protocol support and a new output mode.

**Rationale:**
- `mirror-plugins.sh` already contains all the complex logic for catalog index extraction, OCI image parsing, plugin deduplication, reference rewriting, and `skopeo` orchestration — over 1,300 lines of tested code
- A new tool would duplicate all of this logic and diverge over time
- The `file://` protocol is a natural extension to `install-dynamic-plugins.py`, not a separate concern
- The existing `--to-dir` mode proves the script already supports non-registry output; `--to-local-plugins` is a variation of the same pattern

### Decision 2: Single Consolidated Output Directory

**Chosen:** All artifacts (rewritten YAML, catalog entities, and extracted plugin directories) go under a single root directory (e.g., `/etc/rhdh/extensions/`).

**Rationale:**
- Consumers need one `COPY` in their Containerfile, not multiple
- Consumers need one Quadlet volume mount, not multiple
- The `CATALOG_INDEX_IMAGE` environment variable points to one path; plugin `file://` references are relative within that same tree
- Aligns with the existing `extensions-catalog` volume pattern used in Helm chart deployments
- `/etc/rhdh/extensions/` is semantically correct — these are immutable build-time artifacts, not runtime state

### Decision 3: Bootc Base Image Stays Minimal

**Chosen:** The bootc base image requires no changes. Plugin preparation is entirely a consumer-side concern.

**Rationale:**
- The base image's `plugins: []` design is correct — it makes no assumptions about what plugins a consumer needs
- Baking ~34 default plugins into the base image would add significant size and couple the base to a specific plugin set that changes each release
- The bootc scripts (`wait-for-plugins-and-start.sh`, `prepare-and-install-dynamic-plugins.sh`) are pass-through orchestrators — they call `install-dynamic-plugins.py` inside the RHDH container and don't parse or care about `CATALOG_INDEX_IMAGE` or plugin references
- The `install-dynamic-plugins.py` change comes via the RHDH container image version bump (e.g., `rhdh-hub-rhel9:2.1`), which is a routine Quadlet image tag update, not a feature change in the bootc layer
- Existing Quadlet volume mounts (`/var/lib/rhdh/local-plugins`, `/etc/rhdh/configs`) already support the paths needed

### Decision 4: Consumer-Side Layering Pattern

**Chosen:** Consumers run `mirror-plugins.sh` on a connected workstation, then `COPY` the output into their Containerfile. The consumer's Containerfile layers on top of the bootc base.

**Rationale:**
- Follows the established bootc pattern where the base image provides infrastructure and consumers layer application-specific content
- Consistent with how the Ansible Automation Platform team already layers their plugins (via `Containerfile.rhdh-ansible-bootc`)
- Allows different consumers to select different plugin sets without affecting the base
- The connected workstation handles all network-dependent operations; the resulting image is fully self-contained

## Implementation

### Changes to `install-dynamic-plugins.py` (rhdh repo)

#### 1. `extract_catalog_index()` — Add `file://` protocol handling

The `extract_catalog_index()` function (currently at line 1075) needs a branch at the top to detect `file://` paths. When detected, it skips the `skopeo copy` step and reads `dynamic-plugins.default.yaml` and `catalog-entities/` directly from the local directory:

```python
def extract_catalog_index(catalog_index_image, catalog_index_mount, catalog_entities_parent_dir):
    # NEW: detect file:// protocol
    if catalog_index_image.startswith('file://'):
        local_path = catalog_index_image[len('file://'):]
        default_plugins_file = os.path.join(local_path, 'dynamic-plugins.default.yaml')
        if not os.path.isfile(default_plugins_file):
            raise InstallException(f"Local catalog index at {local_path} does not contain dynamic-plugins.default.yaml")

        # Extract catalog entities if present
        extensions_dir = os.path.join(local_path, 'catalog-entities')
        if os.path.isdir(extensions_dir):
            os.makedirs(catalog_entities_parent_dir, exist_ok=True)
            dest = os.path.join(catalog_entities_parent_dir, 'catalog-entities')
            if os.path.exists(dest):
                shutil.rmtree(dest)
            shutil.copytree(extensions_dir, dest, dirs_exist_ok=True)

        return default_plugins_file

    # EXISTING: OCI pull via skopeo (unchanged)
    ...
```

#### 2. `OciDownloader` class — Add `file://` protocol handling

The `OciDownloader.download()` method (currently at line 710) needs to handle `file://` plugin references. When the plugin package starts with `file://`, it reads the plugin directory from disk instead of calling `skopeo copy`:

```python
def download(self, package):
    (image, plugin_path) = package.split('!')

    # NEW: detect file:// protocol
    if image.startswith('file://'):
        source_dir = os.path.join(image[len('file://'):], plugin_path)
        dest_dir = os.path.join(self.destination, plugin_path)
        if os.path.exists(dest_dir):
            shutil.rmtree(dest_dir)
        shutil.copytree(source_dir, dest_dir)
        return plugin_path

    # EXISTING: OCI download via skopeo (unchanged)
    tar_file = self.get_plugin_tar(image)
    ...
```

#### 3. `OciPluginInstaller.should_skip_installation()` — Skip digest checks for local files

For `file://` references, there is no remote registry to query for digest comparison. The method should use `IF_NOT_PRESENT` pull policy for local files:

```python
def should_skip_installation(self, plugin, plugin_path_by_hash):
    package = plugin['package']
    # NEW: file:// packages don't have remote digests
    if package.split('!')[0].startswith('file://'):
        if plugin['plugin_hash'] in plugin_path_by_hash:
            return True, "already_installed"
        return False, "not_installed"

    # EXISTING: OCI digest checking (unchanged)
    ...
```

### Changes to `mirror-plugins.sh` (rhdh-operator repo)

#### 1. New `--to-local-plugins` flag

Add a new output mode alongside `--to-registry` and `--to-dir`:

```bash
'--to-local-plugins')
  TO_LOCAL_PLUGINS=$(realpath "$2")
  shift 1
  ;;
```

#### 2. New output mode logic

When `--to-local-plugins` is specified, the script:

1. **Extracts the catalog index** (reuses existing `resolve_plugin_index()` logic)
2. **For each plugin**: instead of `skopeo copy` to a registry or OCI dir format, it downloads the OCI image, extracts the first layer tarball, and unpacks the plugin contents to a named directory
3. **Rewrites `oci://` references to `file://` paths** in `dynamic-plugins.default.yaml` and `catalog-entities/*.yaml` using a modified sed pattern:

```bash
# Current pattern (rewrites to registry):
sed -i -E "s|oci://[^/]+(/[^/]+)*(/[^/]+/[^[:space:]\"']+)|oci://$internal_registry\2|g"

# New pattern for --to-local-plugins (rewrites to file://):
sed -i -E "s|oci://[^/]+(/[^/]+)*/([^/:@]+)[^!]*!?||g"
# Then replace each plugin reference line with file:// path:
# file:///opt/app-root/src/extensions/plugins/<plugin-name>
```

4. **Outputs the final directory structure** — no `podman build` step needed since there is no catalog index image to rebuild

#### 3. Output directory structure

```
<output-dir>/
  +-- dynamic-plugins.default.yaml          # refs rewritten to file:// paths
  +-- catalog-entities/
  |     +-- extensions/
  |           +-- *.yaml                    # refs rewritten to file:// paths
  +-- plugins/
  |     +-- backstage-community-plugin-quay/
  |     |     +-- package.json
  |     |     +-- dist/...
  |     +-- backstage-community-plugin-techdocs/
  |     |     +-- package.json
  |     |     +-- dist/...
  |     +-- ... (one directory per plugin)
  +-- rhdh-plugin-local-summary.txt         # mapping of original refs to local paths
```

### No Changes Required in Bootc

The bootc image's scripts are pass-through orchestrators that do not interact with plugin resolution:

| Bootc Script | Role | Touches `CATALOG_INDEX_IMAGE`? |
|---|---|---|
| `wait-for-plugins-and-start.sh` | Waits for postgres, calls prepare script | No |
| `prepare-and-install-dynamic-plugins.sh` | Sets up symlinks, calls RHDH's `install-dynamic-plugins.sh` | No |
| `detect-and-set-base-url.sh` | Detects VM IP, updates `BASE_URL` | No |

The `install-dynamic-plugins.py` change is delivered via the RHDH container image (`rhdh-hub-rhel9`), which the bootc Quadlet pulls. Updating to a version that includes `file://` support is a routine image tag bump in `rhdh.container`:

```ini
# rhdh.container — version bump only
Image=registry.redhat.io/rhdh/rhdh-hub-rhel9:2.1
```

Existing Quadlet volume mounts already cover the necessary paths. The consumer adds one mount for the extensions directory:

```ini
# Consumer's Quadlet override or drop-in
Volume=/etc/rhdh/extensions:/opt/app-root/src/extensions
```

## Usage Examples

### Example 1: Air-Gapped Consumer with Default Plugins

**Phase 1 — Prepare on connected workstation:**
```bash
./mirror-plugins.sh \
  --plugin-index oci://quay.io/rhdh/plugin-catalog-index:2.1 \
  --to-local-plugins /output/rhdh-extensions/
```

**Phase 2 — Consumer Containerfile:**
```dockerfile
FROM registry.redhat.io/rhdh/rhdh-rhel9-bootc:2.1

# Copy all pre-extracted plugins and config to a single location
COPY output/rhdh-extensions/ /etc/rhdh/extensions/

# Point install-dynamic-plugins.py to local catalog index
RUN echo 'CATALOG_INDEX_IMAGE=file:///opt/app-root/src/extensions/' >> /etc/rhdh/rhdh.env
RUN echo 'CATALOG_ENTITIES_EXTRACT_DIR=/opt/app-root/src/extensions/catalog-entities/' >> /etc/rhdh/rhdh.env
```

**Phase 3 — Build VM image:**
```bash
podman build -t my-rhdh-bootc:2.1 -f Containerfile.consumer .
sudo bootc-image-builder build --type qcow2 my-rhdh-bootc:2.1
```

**Phase 4 — Boot disconnected VM:**
```
systemd starts
  -> detect-and-set-base-url.sh (detects VM IP)
  -> postgres.service starts (from embedded image)
  -> rhdh.service starts (from embedded image)
     -> wait-for-plugins-and-start.sh
        -> prepare-and-install-dynamic-plugins.sh
           -> install-dynamic-plugins.py
              -> Reads CATALOG_INDEX_IMAGE=file:///opt/app-root/src/extensions/
              -> Reads dynamic-plugins.default.yaml from disk (no skopeo)
              -> Reads each plugin from file:// path (no skopeo)
              -> Installs to /dynamic-plugins-root/
              -> RHDH starts with all plugins loaded
```

### Example 2: Air-Gapped Consumer with Default + Custom Plugins

```bash
# Prepare default plugins
./mirror-plugins.sh \
  --plugin-index oci://quay.io/rhdh/plugin-catalog-index:2.1 \
  --to-local-plugins /output/rhdh-extensions/

# Prepare additional custom plugins
./mirror-plugins.sh \
  --plugins 'oci://my-registry.example.com/my-custom-plugin:1.0!my-custom-plugin' \
  --to-local-plugins /output/rhdh-extensions/
```

```dockerfile
FROM registry.redhat.io/rhdh/rhdh-rhel9-bootc:2.1

COPY output/rhdh-extensions/ /etc/rhdh/extensions/
COPY my-dynamic-plugins.override.yaml /etc/rhdh/configs/dynamic-plugins/dynamic-plugins.override.yaml

RUN echo 'CATALOG_INDEX_IMAGE=file:///opt/app-root/src/extensions/' >> /etc/rhdh/rhdh.env
```

### Example 3: AAP Team Layering Additional Plugins

```dockerfile
FROM registry.redhat.io/rhdh/rhdh-rhel9-bootc:2.1

# Default plugins from catalog index
COPY output/rhdh-extensions/ /etc/rhdh/extensions/

# AAP-specific plugins (additional)
COPY aap-plugins/ /etc/rhdh/extensions/plugins/

# AAP plugin configuration
COPY dynamic-plugins.override.yaml /etc/rhdh/configs/dynamic-plugins/

RUN echo 'CATALOG_INDEX_IMAGE=file:///opt/app-root/src/extensions/' >> /etc/rhdh/rhdh.env
```

### Example 4: Connected Bootc (No Change Needed)

For connected bootc deployments, the existing OCI-based flow continues to work unchanged:

```bash
# rhdh.env — existing behavior, no changes
CATALOG_INDEX_IMAGE=quay.io/rhdh/plugin-catalog-index:2.1
```

## Alternatives Considered

### Alternative 1: Bake Default Plugins into the Bootc Base Image

- **Approach**: Add `skopeo copy` and extraction steps to the bootc base Containerfile to pre-extract all ~34 default plugins and the catalog index at base image build time.
- **Rejected because**: Contradicts the minimal base image philosophy. Couples the base to a specific plugin set that changes each release. Significantly increases base image size. Forces all consumers to carry plugins they may not need. Different consumers (Ansible, Orchestrator, custom) need different plugin sets.

### Alternative 2: Create a Separate Bootc-Specific Tool

- **Approach**: Build a new standalone script specifically for preparing dynamic plugins for bootc deployments.
- **Rejected because**: Would duplicate all the complex logic already in `mirror-plugins.sh` — OCI image parsing, catalog index extraction, `skopeo` orchestration, plugin deduplication, reference rewriting, fallback registry handling. The scripts would diverge over time. The `--to-local-plugins` mode is a natural extension of `mirror-plugins.sh`, not a different concern.

### Alternative 3: Require a Mirror Registry on the Bootc Appliance

- **Approach**: Run a lightweight container registry (e.g., `registry:2`) on the bootc VM and use the existing `mirror-plugins.sh --to-registry` flow.
- **Rejected because**: A bootc appliance is designed to be a self-contained, minimal system. Adding a registry service increases complexity, resource usage, and attack surface. The existing Helm chart mirror approach works because Kubernetes clusters typically already have a registry. A bootc VM running as an edge appliance does not and should not need one.

### Alternative 4: Patch `dynamic-plugins.default.yaml` at Build Time Without Script Changes

- **Approach**: Consumers manually extract the catalog index with `skopeo`, manually extract each plugin, and manually rewrite all `oci://` references with `sed`/`yq` in their Containerfile.
- **Rejected because**: Requires consumers to replicate the complex logic that `mirror-plugins.sh` already handles — OCI layer extraction, plugin path resolution, reference parsing, fallback handling. Error-prone and not maintainable across releases as plugin sets change.

## Consequences

### Positive

✅ Enables fully air-gapped RHDH deployments on bootc appliances without requiring a mirror registry
✅ Reuses existing `mirror-plugins.sh` infrastructure — no duplication of complex OCI handling logic
✅ Bootc base image remains minimal and unopinionated — no changes needed
✅ Consumer workflow is straightforward: one CLI command to prepare, one `COPY` to include
✅ Backward compatible — existing OCI-based flows (`CATALOG_INDEX_IMAGE=quay.io/...`) continue to work unchanged
✅ Consistent with established patterns used by the Ansible Automation Platform team for their own plugin pre-extraction
✅ `file://` support benefits all deployment methods, not just bootc — any deployment that wants to avoid runtime network calls can use it

### Negative

❌ Requires coordinated changes across two repos (`rhdh` for `install-dynamic-plugins.py` and `rhdh-operator` for `mirror-plugins.sh`)
❌ Consumers must run `mirror-plugins.sh` on a connected machine as a preparation step before building their image
❌ Plugin updates require re-running the preparation step and rebuilding the consumer image — there is no runtime update path in a disconnected environment
❌ The `file://` protocol introduces a second code path in `install-dynamic-plugins.py` that needs testing alongside the existing OCI path

### Neutral

⚖️ Scoped for RHDH 2.1+ — not available in current release cycle
⚖️ The bootc base image version bump to pick up the `file://` support is a routine change, not a feature change in the bootc layer
⚖️ Consumers who don't need air-gap support are unaffected — this is an additive feature

## History

### 2026-05-07 - Initial Draft
- Proposed `file://` protocol support for `install-dynamic-plugins.py` and `--to-local-plugins` mode for `mirror-plugins.sh`
- Consolidated output directory approach based on feedback from Ansible Automation Platform team
- Bootc base image confirmed to require no changes
