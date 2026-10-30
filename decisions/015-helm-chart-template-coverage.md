# ADR: Measure Helm Template Coverage with chart-coverage

## Context

**Problem**: The RHDH Helm chart repository has no template-branch coverage signal. We cannot tell which `if` / `else` / `with` / `range` paths existing CI values actually exercise, and we cannot upload that to Codecov the way the operator uploads Go coverage.

[RHIDP-11864](https://redhat.atlassian.net/browse/RHIDP-11864) asked for unit-test coverage on `rhdh-chart`. Charts are Go templates, not Go, so `cover.out` does not apply. Today:

- Chart-testing (`ct lint` / `ct install`) and Helm test hooks are **pass/fail**. They do not produce a coverage percentage.
- Values used in CI live under `charts/<chart>/ci/`. There are **no** helm-unittest `*_test.yaml` suites in the repo.
- Several community tools exist, but most require rewriting those tests or running a cluster. The spike constraint ([RHIDP-13290](https://redhat.atlassian.net/browse/RHIDP-13290)) was: prefer an OSS tool that measures template branches from **existing** `ci/` files, emits something Codecov accepts, and does not force a chart rewrite.

**Who is impacted**:
- Chart authors, who need to see uncovered template branches on PRs
- QE / Install, who own Helm quality signals
- Anyone comparing chart coverage to operator Codecov coverage

**Constraints**:
- Do not rewrite charts or replace chart-testing
- OSS, pinable, Apache-2.0-compatible
- Codecov-compatible report (Cobertura XML). Go `cover.out` is not required
- First numbers will be low (local baseline: rhdh ~28%, must-gather ~61%, orchestrator-infra ~84%). Coverage must not become a merge gate on day one

Spike notes: [Google doc](https://docs.google.com/document/d/1iMGzEt_tpxikwQ01hFQphLoEBCWeHrXTlTR1g00NGhg/edit). Implementation: [RHIDP-18349](https://redhat.atlassian.net/browse/RHIDP-18349), [rhdh-chart#698](https://github.com/redhat-developer/rhdh-chart/pull/698).

## Decision

Use **[chart-coverage](https://github.com/jCOTINEAU/chart-coverage)** (`helm-coverage.sh`) to measure Helm **template branch** coverage from existing `ci/` values, and upload Cobertura XML to **Codecov** as an informational check.

**Implementation approach**:
- Vendor `helm-coverage.sh` in `rhdh-chart` (Apache-2.0), pinned to a SHA. Do not curl `main` in CI
- New cluster-free GitHub Actions workflow on PRs to `main` / `release-*` and on push to `main`
- Run it on the charts chart-testing already cares about: `rhdh`, `must-gather`, `orchestrator-infra`
- Rewrite Cobertura paths to `charts/<chart>/templates/...` so Codecov can map files
- Keep `codecov.yml` project/patch statuses **informational** until the team picks a real target
- Leave `ct lint` / `ct install` unchanged. This coverage job does not replace install tests

This is **not** Go line coverage and **not** cluster-install coverage. It answers: “which template branches did `ci/` values hit?”

## Alternatives Considered

### Alternative 1: helm-unittest `--coverage`
- **Approach**: Adopt [helm-unittest](https://github.com/helm-unittest/helm-unittest) suites and use `--coverage` (Cobertura/LCOV). Coverage is implemented on helm-unittest `main` and listed for unreleased **1.3.0**.
- **Rejected because**: `rhdh-chart` has no `*_test.yaml` files. Getting a number would mean rewriting CI around helm-unittest, which the spike was asked to avoid. Revisit if the repo later adds unittest suites and 1.3.0 is released.

### Alternative 2: helmcov
- **Approach**: [helmcov](https://github.com/jordan-simonovski/helmcov) renders the chart from values, helm-unittest suite values, and generated branch scenarios. It reports line and branch coverage (`if` / `range` / `with`) and emits Go `coverprofile` plus Cobertura. There is a GitHub Action that can comment on PRs.
- **Why it was only listed in the spike**: helmcov **requires at least one** `*_test.yaml`. That is the same rewrite as Alternative 1, so it was not run as a separate tool.
- **Rejected because**: same adoption cost as helm-unittest. Extra generated scenarios do not remove the need to introduce unittest suites first. You cannot point `--tests` at `charts/rhdh/ci/` (those are Helm values files) or at `templates/tests/` (Helm test-hook Pods). chart-coverage already produces Cobertura from `ci/` with no new test format. Revisit only if we adopt helm-unittest for assertions and then want helmcov’s scenario generator on top.

### Alternative 3: Terratest / chart-testing as “coverage”
- **Approach**: Treat `ct install` or [Terratest](https://github.com/gruntwork-io/terratest) Go tests as the coverage story.
- **Rejected because**: those tools answer pass/fail against a cluster (or a rendered install). They do not emit per-template branch percentages or Codecov XML. We already have chart-testing; it does not solve RHIDP-11864.

### Alternative 4: Static `.Values` key coverage
- **Approach**: Lint which `values.yaml` keys are referenced in templates (tools in the “helm-chart-values-coverage” class).
- **Rejected because**: that is schema/key usage, not execution of `if` / `else` / `with` / `range`. It would not tell us which branches `ci/` files actually take.

### Alternative 5: Write our own instrumenter
- **Approach**: Maintain a custom template instrumenter and reporter in `rhdh-chart`.
- **Rejected because**: chart-coverage already does this (temp copy, markers, `helm template`, Cobertura). Duplicating it is extra maintenance for no extra signal.

### Alternative 6: Wait for a “Helm-native” coverage tool
- **Approach**: Do nothing until Helm or helm-unittest ships a released, values-file-only coverage command.
- **Rejected because**: the epic needs a path now. chart-coverage is OSS, pinable, and works with current `ci/` files. We can supersede this ADR later if a released unittest coverage story lands and we have suites.

## Consequences

### Positive
- ✅ Coverage from files we already maintain (`ci/`), no chart or unittest rewrite
- ✅ Cobertura XML matches what Codecov already accepts (same idea as the operator, different payload)
- ✅ Cluster-free CI job; does not slow or replace `ct install`
- ✅ Uncovered template branches become visible on PRs once the `main` baseline exists

### Negative
- ❌ First rhdh figure is ~28%. That is expected (only `ci/` branches), but it looks “low” next to Go coverage
- ❌ Vendoring ~1.5k lines of upstream bash; we exclude it from Differential ShellCheck and Sonar rather than forking the tool
- ❌ chart-coverage is a small project. We pin a SHA and replace the file to upgrade
- ❌ Nested helper / straight-line `define` instrumentation has known upstream limits; numbers are directional, not an auditor-grade trace
- ❌ Fork PRs do not get `CODECOV_TOKEN`; upload is best-effort (`fail_ci_if_error: false`)

### Neutral
- ⚖️ Informational Codecov checks: visible, not a merge gate, until the team sets a target
- ⚖️ `backstage` and demo orchestrator software-template charts stay out, consistent with `ct.yaml`
- ⚖️ helm-unittest / helmcov remain valid later if we introduce `*_test.yaml` suites; this ADR does not forbid that