# ADR: OLM FBC Channel Management for RHDH Operator

## Context

**Problem**: The RHDH operator's default OLM channel (`fast`) contains every version published so far — from 1.0 through the latest 2.y release — including versions with breaking changes between them. Combined with a wide `skipRange` (`>=1.0.0 <X.Y.0`) and `Automatic` being the default Subscription approval mode in OLM, users who did not explicitly change their channel or approval strategy will receive a 2.y upgrade as soon as it is published, even though the 1.y-to-2.y transition introduces major breaking changes (new frontend system, configuration structure changes) that require deliberate migration.

The operator already publishes per-minor-version channels (`fast-1.10`, `fast-2.1`, `fast-2.2`, etc.), and the [product installation documentation](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_on_openshift_container_platform/index#install-the-rhdh-operator_install-rhdh-on-ocp-with-the-operator) recommends switching to these versioned channels for controlled upgrades. However, since `fast` is the default channel, users who did not switch to a versioned channel may end up with automatic upgrades across breaking version boundaries.

This creates two problems:

1. **Unsolicited breaking upgrades**: Users who installed via the default `fast` channel with automatic approval get rolled from 1.10.z to 2.1.0 without opting in, likely failing due to incompatible configuration.

2. **Overly wide `skipRange`**: The CSV `skipRange` annotation (`>=1.0.0 <2.y.0`) allows OLM to skip arbitrarily many versions in a single jump — e.g., from 1.0.z straight to 2.1.0. The team only tests sequential `.y` upgrades, so skipping versions is an unsupported path.

Additionally, the midstream build tooling that renders FBC catalogs does not enforce the channel model: it unconditionally injects new bundles into `fast` regardless of version, hardcodes `skipRange` to `<X.Y.0` (spanning back to 0.0.0), and can resolve the `replaces` predecessor from the wrong channel — causing upgrade edges that cross major version boundaries.

**Who is impacted**:
- RHDH users on `fast` with automatic approval who would receive an unsolicited breaking upgrade
- RHDH users on `fast-X.Y` channels who could hit incorrect upgrade edges due to wrong `replaces`/`skipRange`
- The RHDH team maintaining FBC catalogs and the build tooling

## Decision

Deprecate the generic `fast` channel, default to per-minor-version `fast-X.Y` channels, narrow `skipRange` to force incremental upgrades, and fix the build tooling to enforce all of this automatically.

### 1. Deprecate the `fast` channel and default to `fast-X.Y`

Mark the `fast` channel with [`olm.channel.deprecations` and `olm.deprecated`](https://olm.operatorframework.io/docs/reference/file-based-catalogs/#olmdeprecations) properties in the FBC catalog. Change the default channel in the operator bundle metadata from `fast` to `fast-X.Y` (e.g., `fast-2.1`).

The `fast` channel cannot be removed entirely because removing a channel breaks OLM namespace-wide resolution, which breaks dependency resolution if multiple operators are installed in the same namespace. If a user is subscribed to `fast` and the channel is removed, their Subscription enters `ResolutionFailed` status. While this would eventually push them to switch to a `fast-X.Y` channel, it would also block resolution for every other operator in that namespace. We recommend installing the RHDH operator in its own `rhdh-operator` namespace, but users may install additional operators there or run all their operators in a shared namespace. We should not break resolution for those scenarios.

Instead, `fast` is frozen at the last 1.y entry and marked deprecated, preserving a valid (if terminal) state for those users without impacting namespace-wide resolution.

### 2. Narrow `skipRange` to force sequential upgrades

Change `skipRange` from `>=1.0.0 <X.Y.0` (allowing jumps from any version) to `>=X.(Y-1).0 <X.Y.0` (requiring the previous minor version). For example:

- `fast-2.1` channel entry: `skipRange: >=1.10.0 <2.1.0` — requires 1.10.z before moving to 2.1
- `fast-2.2` channel entry: `skipRange: >=2.1.0 <2.2.0` — requires 2.1.z before moving to 2.2

Z-stream updates within a minor version are unrestricted: upgrading from 2.1.0 directly to 2.1.3 is allowed since z-stream releases do not contain new breaking changes.

### 3. Freeze `fast` in the FBC catalogs

Remove all 2.y entries from the `fast` channel in the FBC catalog files, leaving only 1.y entries. This ensures users on `fast` are not offered 2.y upgrades.

### 4. Fix the build tooling to enforce the channel model

Update the midstream catalog rendering script to prevent regression:

- **Guard `fast` for 2.y+**: When rendering a version >= 2.0, preserve the existing `fast` channel block unchanged instead of injecting a new entry. This structurally prevents new versions from landing in the deprecated channel.

- **Derive `skipRange` automatically**: Instead of hardcoding a wide `skipRange`, derive the lower bound from the `replaces` target's major.minor version. This ensures `skipRange` is always scoped to the correct version range without manual intervention.

- **Resolve `replaces` across minor boundaries**: When determining the upgrade predecessor for a new minor version (e.g., 2.2.0), check the previous minor's `fast-X.(Y-1)` channel (e.g., `fast-2.1`) instead of falling back to the generic `fast` channel. This prevents `replaces` from pointing across major version boundaries.

### 5. Defensive guard for 1.10 branch

On the `rhdh-1.10-rhel-9` branch, add the same `fast` channel guard to prevent 1.10.z releases from accidentally creating upgrade edges into 2.y.

**Implementation approach**:

- Update the operator bundle metadata (default channel, CSV `skipRange`) upstream on `main` and `release-2.1`
- Update FBC catalog files and fix the catalog rendering script in midstream
- Freeze the `fast` channel by removing 2.y entries and fix the `skipRange`/`replaces` values in existing catalog entries

## Alternatives Considered

### Alternative 1: Remove the `fast` channel entirely
- **Approach**: Delete the `fast` channel from all FBC catalogs
- **Rejected because**: Removing a channel breaks OLM namespace-wide dependency resolution. Any user subscribed to `fast` would enter `ResolutionFailed` status, which also blocks resolution for every other operator installed in the same namespace. We cannot guarantee users follow our recommendation to install the RHDH operator in its own namespace.

### Alternative 2: Create a new `fast2` channel for 2.y+
- **Approach**: Keep `fast` for 1.y, create a new `fast2` channel starting at 2.1 that contains all 2.y versions
- **Rejected because**: Minor product versions can also contain breaking changes, as we have seen in past releases. A `fast2` channel spanning all 2.y versions would reproduce the same problem within the 2.y line — users with automatic approval would get rolled from 2.1 to 2.2 without opting in, potentially hitting breaking changes. Per-minor `fast-X.Y` channels already exist and provide the correct granularity. Adding `fast2` would be redundant and would eventually need the same deprecation treatment once 2.y-to-2.(y+1) breaking changes surface.

### Alternative 3: Keep `fast` as a rolling channel with correct upgrade edges
- **Approach**: Continue adding all versions to `fast`, but fix `replaces` to create a sequential chain (1.10 -> 2.1 -> 2.2) and narrow `skipRange`
- **Rejected because**: Users with automatic approval on `fast` would still get breaking upgrades without opt-in. Even with correct upgrade edges, transitions between minor or major versions may require manual migration steps that automatic upgrades cannot perform.

### Alternative 4: Fix only the catalog data, not the tooling
- **Approach**: Manually correct `skipRange` and `replaces` in the current catalog files without changing the rendering script
- **Rejected because**: The next render would reintroduce the same bugs. The tooling is the source of truth for rendered catalogs, so fixing it is essential to prevent regression.

## Consequences

### Positive
- ✅ Upgrading to a new minor or major version becomes a conscious decision — users must explicitly switch their Subscription channel, rather than being upgraded automatically
- ✅ `skipRange` enforces sequential minor upgrades, matching the tested and supported upgrade paths
- ✅ `skipRange` and `replaces` are automatically derived by the build tooling, eliminating a class of manual errors
- ✅ Structural guards in the build tooling prevent future regressions without relying on developer discipline
- ✅ Namespace-wide OLM resolution is preserved — freezing `fast` instead of removing it avoids breaking other operators

### Negative
- ❌ Users on `fast` are stuck at the last 1.y release and must manually switch to a `fast-X.Y` channel to get 2.y — requires communication and documentation
- ❌ Every minor version upgrade requires users to manually change their Subscription channel (e.g., `fast-2.1` to `fast-2.2`)

### Neutral
- ⚖️ `opm validate` catches structural issues (e.g., multiple channel heads) but not semantic issues (e.g., wrong `replaces` target) — manual review of upgrade edges remains necessary
- ⚖️ The frozen `fast` channel will likely remain deprecated indefinitely — the namespace-wide resolution impact that prevented its removal does not go away even after 1.y reaches EOL

## References

- [RHIDP-17820](https://redhat.atlassian.net/browse/RHIDP-17820) — Parent issue: deprecate `fast` channel, default to `fast-X.Y`, reduce `skipRange`
- [RHIDP-17980](https://redhat.atlassian.net/browse/RHIDP-17980) — 1.10 branch defensive guard
- [ADR 004: OLM v1 Adoption](./004-olmv1-adoption.md) — Related decision on FBC adoption
- Upstream PRs: [#3821 (release-2.1)](https://github.com/redhat-developer/rhdh-operator/pull/3821), [#3822 (main)](https://github.com/redhat-developer/rhdh-operator/pull/3822) — Deprecate `fast`, change default channel, narrow `skipRange`
- Midstream MRs: [!831](https://gitlab.cee.redhat.com/rhidp/rhdh/-/merge_requests/831), [!832](https://gitlab.cee.redhat.com/rhidp/rhdh/-/merge_requests/832) — Remove 2.y from `fast`; [!833](https://gitlab.cee.redhat.com/rhidp/rhdh/-/merge_requests/833), [!834](https://gitlab.cee.redhat.com/rhidp/rhdh/-/merge_requests/834) — Fix `skipRange`/`replaces` and build tooling; [!836](https://gitlab.cee.redhat.com/rhidp/rhdh/-/merge_requests/836) — 1.10 guard
- [Slack discussion](https://redhat-internal.slack.com/archives/C04CUSD4JSG/p1791547448888109) — Original thread where the channel model was discussed and decided
- [RHDH installation docs](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html-single/installing_red_hat_developer_hub_on_openshift_container_platform/index#install-the-rhdh-operator_install-rhdh-on-ocp-with-the-operator) — Product documentation recommending versioned channels
- [OLM FBC deprecation schema](https://olm.operatorframework.io/docs/reference/file-based-catalogs/#olmdeprecations) — `olm.deprecations` specification for marking channels as deprecated
