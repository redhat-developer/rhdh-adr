# ADR: Disable CI Testing at Stream EOL

## Context

**Problem**: Unclear whether CI E2E / nightly testing for an RHDH minor stream should keep running (or be restored) after published End of Life when customers have support exceptions.

RHDH publishes a [product life cycle](https://access.redhat.com/support/policy/updates/developerhub). When a minor stream reaches EOL, CI maintainers stop related test jobs and channels. Support exceptions can still cover customers on that stream past EOL, which raised the question of whether engineering must keep CI alive for the exception window.

This ADR documents existing practice that was already followed but not written down. It came into focus when the 1.8 test channel was archived on the EOL date while customers remained under support exception, and was discussed in Slack and an Architecture call.

Recent support exceptions for EOL streams (for example 1.5 and 1.8) illustrate the typical scope today: **support for a product version past published EOL — support only — no bug or CVE fixes or patching**. Under that wording there is no expectation of new z-stream builds or patches, so the product code under test is frozen.

**Who is impacted:**

- **CI maintainers**: Need a clear stop condition for EOL-stream jobs and channels
- **Support**: Owns ticket handling during support-only exceptions
- **Engineering / Architecture**: Need aligned expectations so CI testing is not assumed for EOL streams without an explicit delivery obligation
- **Customers on exceptions**: Receive Support engagement per the exception; not continuous CI coverage of the EOL stream

**Constraints:**

- Support-only exceptions do not require bug fixes, CVE fixes, or patching
- Running nightlies has cloud cost and maintenance cost even when no new builds are produced
- Lifecycle policy remains the source of truth for when a stream is EOL

**Out of scope for this ADR:**

- Konflux pipelines and productization policy for EOL streams
- Future Extended Update Support (EUS) or exception wording that requires delivering patches or new z-streams (revisit if that changes)

## Decision

Stop CI E2E / nightly testing for an RHDH minor stream when that stream reaches published EOL. Support-only support exceptions do not keep testing in scope.

This is a statement of existing practice, not a change in behavior.

**Implementation approach:**

1. **At published EOL**: Stop running CI E2E / nightly jobs (and related test-channel workloads) for that minor stream.
2. **Support-only exceptions**: Do not keep or restore those jobs for the exception window. In-scope work is Support answering tickets per the exception agreement — not engineering test coverage.
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

## Consequences

### Positive

✅ **Clear stop condition**: EOL of the published life cycle ends active CI testing for that stream
✅ **Cost control**: Nightlies and related workloads are not kept running for frozen code under support-only exceptions
✅ **Aligned ownership**: Support owns support-only exception engagement; CI is not assumed to cover EOL streams
✅ **Documented practice**: Makes the existing default explicit so cleanup at EOL does not trigger re-enable debates

### Negative

❌ **No ongoing regression signal** on EOL streams during a support-only exception window
❌ **Cannot claim CI coverage** as part of the exception; Support handles tickets without continuous automated verification of the EOL stream

### Neutral

⚖️ **Konflux / productization** remain a separate policy question and are not decided here
⚖️ **EUS or delivery-bearing exceptions** would reopen whether testing (and builds) must resume; adhere to the published life cycle and the specific exception wording if that changes
