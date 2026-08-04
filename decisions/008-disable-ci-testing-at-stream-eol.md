# ADR: Disable CI Testing at Stream EOL

## Context

**Problem**: Unclear whether CI E2E / nightly testing for an RHDH minor stream should keep running (or be restored) after published End of Life when customers have support exceptions.

RHDH publishes a [product life cycle](https://access.redhat.com/support/policy/updates/developerhub). After the Maintenance Support phase ends, the release is End of Life: software and documentation may remain available, but **no technical support will be provided** under that policy. CI maintainers therefore stop related E2E / nightly jobs and test channels at EOL. Separately, commercial support exceptions can still cover customers on that stream past EOL. That raised the question of whether engineering must keep CI alive for the exception window.

This ADR documents existing practice that was already followed but not written down. It came into focus when the 1.8 test channel was archived on the EOL date while customers remained under support exception, and was aligned in an Architecture call (following Slack discussion with CI maintainers).

Recent past-EOL support exceptions for RHDH (for example on the 1.5 and 1.8 streams) used the Support Exception type **support for a product version past published EOL — support only — no bug or CVE fixes or patching**. That classification does not restore Full or Maintenance Support delivery: there is no expectation of new z-stream builds or patches, so the product code under test is frozen. (Exception tickets themselves are not linked here; they are customer-bearing. The published baseline remains the [RHDH life cycle](https://access.redhat.com/support/policy/updates/developerhub).)

**Scope of “CI testing” in this ADR:** scheduled / continuous **E2E and nightly** jobs for that minor stream, including related test-channel workloads. It does **not** prescribe policy for unit or other PR-triggered checks on a dormant release branch, if such a branch still exists.

**Who is impacted:**

- **CI maintainers**: Need a clear stop condition for EOL-stream E2E / nightly jobs and channels
- **Support**: Owns ticket handling during support-only exceptions
- **Engineering / Architecture**: Need aligned expectations so CI E2E / nightly coverage is not assumed for EOL streams without an explicit delivery obligation
- **Customers on exceptions**: Receive Support engagement per the exception; not continuous CI coverage of the EOL stream

**Constraints:**

- Support-only exceptions do not require bug fixes, CVE fixes, or patching
- Running nightlies has cloud cost and maintenance cost even when no new builds are produced
- The published life cycle remains the source of truth for when a stream is EOL

**Out of scope for this ADR:**

- Konflux pipelines and productization policy for EOL streams
- Future Extended Update Support (EUS) or exception wording that requires delivering patches or new z-streams (revisit if that changes)
- One-off manual reproduction outside CI policy (Support / engineering escalation on a ticket)

## Decision

Stop CI E2E / nightly testing for an RHDH minor stream when that stream reaches published EOL. Support-only support exceptions do not keep that testing in scope.

This is a statement of existing practice, not a change in behavior.

**Implementation approach:**

1. **At published EOL**: Stop running CI E2E / nightly jobs (and related test-channel workloads) for that minor stream.
2. **Support-only exceptions**: Do not keep those jobs running, and **do not restore them** for a support-only exception window—including accidental or ad-hoc re-enable—without a new architectural decision. In-scope work is Support answering tickets per the exception agreement, not engineering test coverage.
3. **Future delivery obligations**: If a future exception or EUS requires new builds or patches, that is a different commitment and needs a separate decision; this ADR does not cover it.

How job configs are removed from active use (disable, delete, archive) is left to CI maintainers as an implementation detail.

## Alternatives Considered

### Alternative 1: Keep full nightlies through the exception end date
- **Approach**: Leave all EOL-stream CI E2E / nightly jobs running until every support exception for that stream ends
- **Rejected because**: Support-only exceptions imply no new builds or patches; continuous CI adds cloud and maintenance cost without a corresponding engineering delivery obligation

### Alternative 2: Keep a subset of jobs (e.g. OpenShift-only)
- **Approach**: Run only platforms/install methods known to be used by exception customers
- **Rejected because**: Still pays cost and maintenance for frozen code; the support-only exception type does not require ongoing test coverage, and customer platform mix is often incomplete or unclear

### Alternative 3: Decide case-by-case in Architecture calls
- **Approach**: Re-discuss each EOL stream and each support-exception request as it appears
- **Rejected because**: No predictable process for CI, Support, and engineering; this ADR exists to document the default for support-only exceptions

### Alternative 4: On-demand / manual re-run of EOL jobs for a Support ticket
- **Approach**: Leave continuous nightlies off, but allow CI maintainers to manually re-trigger EOL-stream E2E jobs when Support asks for signal on a ticket
- **Rejected because**: Not continuous coverage, still incurs ops and cluster cost, and blurs CI policy with ticket triage. One-off reproduction for a customer case remains a Support / engineering escalation outside this ADR, not a standing CI obligation

## Consequences

### Positive
- ✅ **Clear stop condition**: EOL of the published life cycle ends active CI E2E / nightly testing for that stream
- ✅ **Cost control**: Nightlies and related workloads are not kept running for frozen code under support-only exceptions
- ✅ **Aligned ownership**: Support owns support-only exception engagement; CI is not assumed to cover EOL streams
- ✅ **Documented practice**: Makes the existing default explicit so cleanup at EOL does not trigger re-enable debates

### Negative
- ❌ **No ongoing regression signal** on EOL streams during a support-only exception window
- ❌ **Cannot claim CI coverage** as part of the exception; Support handles tickets without continuous automated verification of the EOL stream
- ❌ **Expectation gap**: Customers or Support may assume CI still runs past EOL and be surprised when debugging; EOL / exception communications should not imply continuous CI coverage

### Neutral
- ⚖️ **Konflux / productization** remain a separate policy question and are not decided here
- ⚖️ **EUS or delivery-bearing exceptions** would reopen whether testing (and builds) must resume; adhere to the published life cycle and the specific exception wording if that changes
