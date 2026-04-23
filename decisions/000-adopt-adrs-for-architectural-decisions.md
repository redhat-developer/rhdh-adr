# ADR: Adopt Architecture Decision Records for RHDH

## Context

**Problem**: Architectural decisions for RHDH are made in scattered conversations across Slack threads, video calls, JIRA tickets, and Google Docs, making it difficult to understand why past decisions were made or what alternatives were considered.

As RHDH grows in scope and contributors, the team faces recurring challenges:
- New contributors lack context on why the architecture looks the way it does
- Decisions get revisited repeatedly because there is no record of prior discussion and trade-offs
- Knowledge is concentrated in the heads of a few long-tenured team members
- Discussions happen synchronously in meetings, excluding contributors in different time zones or those who join later
- Implementation choices are documented (in code and JIRA), but the reasoning behind architectural choices is not

**Who is impacted**:
- Current contributors who revisit settled decisions due to missing context
- New contributors who need to understand the rationale behind existing architecture
- Team leads who need a structured review process for cross-cutting decisions
- Downstream consumers of RHDH who want visibility into architectural direction

**Constraints**:
- The process must be lightweight enough that it doesn't discourage writing ADRs
- Must integrate with existing GitHub-based workflows (PRs, reviews)
- Should not replace JIRA for implementation tracking or day-to-day task management

## Decision

Adopt **Architecture Decision Records (ADRs)** as the standard practice for documenting significant architectural decisions for RHDH.

ADRs will be stored in a dedicated repository (`rhdh-adr`) and follow a PR-based lifecycle where the PR state represents the ADR status: Open = Proposed, Merged = Accepted, Closed = Rejected.

**Implementation approach**:
- **Dedicated repository**: ADRs live in `rhdh-adr`, separate from implementation code, so they can be reviewed and discussed independently
- **Template-driven**: A standard template (`ADR-TEMPLATE.md`) ensures consistency across ADRs while keeping the bar low for authors
- **PR-based workflow**: Decisions are proposed, discussed, and finalized through GitHub pull requests, providing a permanent and searchable discussion history
- **Immutable once accepted**: Merged ADRs are not modified; significant changes require a new ADR that references the original
- **Scope guidance**: ADRs are written for decisions that affect multiple components, have long-term impact, are difficult to reverse, or involve meaningful trade-offs

**When to write an ADR**:
- API design, data models, or CRD changes affecting multiple components
- Deployment patterns, configuration mechanisms, or operator architecture changes
- Decisions involving trade-offs that the team debated
- Changes that someone in 6 months might wonder "why did we do this?"

**When NOT to write an ADR**:
- Implementation details, bug fixes, or temporary workarounds
- Obvious choices with no realistic alternatives

For detailed writing guidelines, see [ADR-GUIDE.md](../ADR-GUIDE.md). To create a new ADR, use the [ADR-TEMPLATE.md](../ADR-TEMPLATE.md).

## Alternatives Considered

### Alternative 1: Continue with informal decision-making
- **Approach**: Keep making decisions in Slack, meetings, and JIRA tickets without a formal record
- **Rejected because**: This is the status quo that caused the problems described in Context. Decisions are lost, revisited, and inaccessible to new contributors

### Alternative 2: Decision log in Google Docs
- **Approach**: Maintain shared documents listing architectural decisions
- **Rejected because**: Documents drift without clear ownership, and there is no built-in mechanism for asynchronous discussion or version history tied to specific changes

### Alternative 3: Embed ADRs in each implementation repository
- **Approach**: Store ADRs alongside the code they relate to, in a `docs/adr/` directory within each repo
- **Rejected because**: Many RHDH architectural decisions span multiple repositories. A central repository provides a single place to discover all decisions and avoids scattering cross-cutting ADRs across repos

## Consequences

### Positive
✅ Preserves decision context and rationale for future contributors
✅ Reduces repeated discussions about previously settled architectural choices
✅ Enables asynchronous, inclusive review across time zones via GitHub PRs
✅ Creates a searchable history of architectural evolution
✅ Low barrier to entry with a simple template and familiar PR workflow
✅ A centralized ADR repository can be surfaced in our internal dogfooding RHDH instances using the [Backstage ADR plugin](https://github.com/backstage/community-plugins/tree/main/workspaces/adr/plugins/adr)

### Negative
❌ Adds a process step before implementation of significant architectural changes
❌ Requires discipline to write ADRs consistently; the practice only works if the team commits to it
❌ Central repository means ADRs are not co-located with the code they describe

### Neutral
⚖️ Does not replace JIRA, Slack, or meetings; complements them by capturing the outcome
⚖️ ADR quality will vary; the template and review process help but cannot guarantee thoroughness
⚖️ Open ADR PRs should be regularly surfaced in architecture calls to ensure timely review and avoid stale proposals
