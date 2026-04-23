# ADR Approval Guidelines

## Purpose

These guidelines establish how Architecture Decision Records (ADRs) are reviewed and approved in the RHDH project, based on meritocracy and consensus principles.

## Roles and Responsibilities

**There are two roles in the ADR process:**

### Author
The person who creates the ADR is **fully responsible** for driving it to completion:
- **Announce** the ADR in appropriate channels with timeline
- **Facilitate** review discussion (answer questions, moderate feedback)
- **Update** ADR based on feedback (or explain why not)
- **Decide** when consensus is reached
- **Merge or close** the PR when ready
- **Own** the decision throughout the lifecycle

The Author is not a passive participant waiting for approval - they actively drive the process.

### Reviewers
Those who provide feedback on the ADR:
- **Read** and understand the ADR
- **Provide** reasoned feedback (blocking or non-blocking)
- **Engage** in discussion if needed
- **Trust** the Author to make final call on merging

Reviewers do not control the process - they contribute input, but the Author decides.

### No Global Facilitator/Maintainer

**Important:** There is no central ADR maintainer, gatekeeper, or approval authority.
- No one "owns" the ADR repository
- No single person approves or blocks all ADRs
- Each Author drives their own ADR
- Distributed ownership model (meritocracy, not hierarchy)

### Out of Scope

**Execution/Implementation** is separate from ADR approval:
- Merging an ADR = decision is documented and approved
- Implementation tracking happens elsewhere (JIRA, issues, etc.)
- Author is not necessarily the implementer
- ADR approval does not guarantee implementation timeline

## Announcing an ADR

**When you create an ADR PR:**

1. **Post in stable communication channel** (e.g., `#rhdh-team` Slack channel) e.g.:
   ```
   📋 New ADR for review: [ADR-XXX: Title]
   PR: [link]
   Review period: [start date] → [end date] (minimum 1 week)
   Interested parties: @person1 @person2 @team
   ```

2. **Minimum review period: 1 week**
   - Start counting from announcement date
   - Allows time for thoughtful review across timezones/schedules
   - Can be extended if reviewers request more time

3. **Tag relevant stakeholders**
   - Those affected by the decision
   - Those who will implement it
   - Subject matter experts in the area

## Review Period Extensions

**Reviewers can request more time:**

If you need more time to review, comment on the PR:
```
I'm interested in reviewing this but need until [date] to provide feedback.
```

Author should accommodate reasonable extension requests (within reason - not indefinitely).

## Who Should Review

**Interested parties principle:**
- Those **affected** by the decision (users of the API, operators, plugin developers)
- Those **implementing** the decision (engineers doing the work)
- Subject matter experts in the relevant area (Kubernetes operators, air-gap deployments, etc.)

**Meritocracy principle:**
- Those doing the implementation work have stronger voice
- Those with expertise in the domain have stronger voice
- All feedback is valued, but weight differs based on involvement/expertise

**You don't need everyone's approval:**
- Seek input from affected parties
- Not everyone needs to approve
- Silence after review period = no objection

## Approval Criteria

### Consensus-Seeking (Not Majority Vote)

- Goal is **rough consensus**, not unanimous agreement
- Seek to understand and address objections
- "Disagree and commit" is acceptable if concerns are heard and discussed

### Lazy Consensus

- After review period (minimum 1 week), **silence = consent**
- Don't wait indefinitely for approval from everyone
- If critical stakeholder is silent, follow up directly before merging

### Reasoned Objections

Objections must explain **why**:
- ✅ "This violates air-gap constraint because..."
- ✅ "Alternative X is better because..."
- ✅ "This creates technical debt: [specific risk]"
- ❌ "I don't like it" (insufficient)
- ❌ "We should wait" (without specific reason)

**Author must address objections:**
- Respond to concerns in PR comments
- Update ADR if valid points raised
- Explain why objection isn't addressed (if declining)

### Blocking vs Non-Blocking Feedback

**Blocking objections** (must resolve before merge):
- "This will cause data loss"
- "This violates stated constraint"
- "This makes implementation impossible"
- "Critical alternative not considered"

**Non-blocking feedback** (should consider, but author decides):
- "Consider alternative X"
- "This could be improved by Y"
- "Minor concern about Z"
- "Wording unclear in section N"

Author must address blocking concerns. Author should consider non-blocking feedback but has final say.

### Technical Merit Over Politics

- Decisions based on **technical rationale**, not organizational politics
- Trade-offs acknowledged honestly (not hidden to get approval)
- Data and evidence preferred over opinion
- "This is how we've always done it" is not sufficient rationale

## When to Merge

**Merge criteria:**
- ✅ Review period elapsed (minimum 1 week from announcement)
- ✅ All extension requests honored (if reviewers asked for more time)
- ✅ No unresolved blocking objections
- ✅ Author has responded to all feedback (addressed or explained why not)

**You don't need:**
- ❌ Explicit approval from every tagged person
- ❌ Specific number of approvals (2+, 3+, etc.)
- ❌ Sign-off from specific roles

**Lazy consensus:** If reasonable people had opportunity to object and didn't, proceed.

## Examples

### Good Review Process

1. Author posts ADR PR in `#rhdh-team`: "ADR-006: Plugin Registry, review until Dec 15"
2. Three people comment with questions/suggestions
3. One person says "Need until Dec 18 to review air-gap implications"
4. Author responds to all comments, updates ADR based on feedback
5. Dec 18 arrives, person posts review with minor suggestions (non-blocking)
6. Author acknowledges suggestions, merges on Dec 19
7. **Result:** Consensus reached, decision documented

### Poor Review Process

1. Author opens PR, doesn't announce anywhere
2. Merges after 2 days with no review
3. **Result:** No consensus, affected parties didn't have chance to review

### Handling Disagreement

1. Author posts ADR, two reviewers have conflicting suggestions
2. Author facilitates discussion between reviewers in PR comments
3. Reviewers reach compromise or "agree to disagree"
4. Author documents both perspectives in ADR (if valuable)
5. Merges with rough consensus (not unanimous)
6. **Result:** Decision made, dissenting view acknowledged

## Related Documents

- **ADR-GUIDE.md**: How to write and structure ADRs
- **ADR-TEMPLATE.md**: Template for creating new ADRs
- **README.md**: Overview of ADR repository
