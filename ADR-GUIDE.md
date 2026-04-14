# ADR Writing Guide

## What is an ADR?

An **Architecture Decision Record (ADR)** is a document that captures an important architectural decision made along with its context and consequences.

**Purpose:**
- **Provide a predictable space for asynchronous discussion** - ADRs give teams a dedicated location to review and discuss architectural decisions thoughtfully at their own pace, without needing to coordinate meeting schedules
- **Focus on architecture, not implementation** - Unlike issue trackers (JIRA) which focus on implementation tasks, ADRs focus on the "why" - exploring problems, trade-offs, and alternatives before diving into how to build
- **Document and preserve decision history** - Captures why choices were made, what alternatives were considered, and the trade-offs involved. Prevents revisiting settled decisions and maintains institutional memory as the team evolves

## When to Write an ADR

Write an ADR when making decisions that:

✅ **Affect multiple components or teams** (e.g., API design, data models)
✅ **Have long-term impact** (e.g., deployment patterns, configuration mechanisms)
✅ **Are difficult to reverse** (e.g., database choices, operator architecture)
✅ **Involve trade-offs** (e.g., performance vs. maintainability)
✅ **Need team alignment** (e.g., flavour system design, plugin infrastructure)

❌ **Don't write ADRs for:**
- Implementation details (how to write a specific function)
- Temporary workarounds
- Obvious choices with no alternatives
- Pure bug fixes without architectural impact

## Template Structure

### Required Sections

#### 1. **Title**
```markdown
# ADR: [Short Title of Decision]
```

- Keep it short and descriptive (5-10 words)
- Use active voice describing what is being done
- Examples:
  - ✅ "Flavour-Based Configuration for Backstage"
  - ✅ "Plugin Infrastructure Configuration"
  - ❌ "Configuration" (too vague)
  - ❌ "A discussion about how we should handle flavours" (too wordy)

#### 2. **Context**
```markdown
## Context

**Problem**: [What problem are we solving?]

[Describe the situation...]
```

**What to include:**
- The problem or limitation you're addressing
- Current state and why it's insufficient
- Who is affected (users, developers, operators)
- Constraints (technical, business, timeline)
- Requirements that must be met

**Tips:**
- Be specific and concrete
- Use examples to illustrate the problem
- Focus on **why** the decision is needed, not **what** the decision is (that's next section)
- This section answers: "Why are we even discussing this?"

**Example:**
```markdown
## Context

**Problem**: No easy way to deploy Backstage with well-known configurations.

The RHDH Operator provides default configurations via ConfigMaps, but profiles are
operator-level and require different OLM bundles. There's no lightweight way to deploy
instances with common patterns (Orchestrator-enabled, AI-enabled, etc.) without writing
complex CR specs.

This forces users to:
- Manually configure every instance from scratch
- Maintain complex CR specs even for common patterns
- Duplicate configuration across similar instances
```

#### 3. **Decision**
```markdown
## Decision

[What are we going to do?]

**Implementation approach**:
- [Key aspect 1]
- [Key aspect 2]
```

**What to include:**
- Clear statement of the decision
- Key implementation details (bullet points work well)
- Brief code/config examples if helpful
- How it solves the problem from Context section

**Tips:**
- Start with a one-sentence summary of the decision
- Use bullet points for clarity
- Include just enough detail to understand the approach
- Link to separate docs for full implementation details

**Example:**
```markdown
## Decision

Introduce **Flavour-Based Configuration**: a mechanism for selecting pre-configured
templates for Backstage deployments.

**Implementation approach**:
- Flavours stored in `/default-config/flavours/<name>/`
- User specifies enabled flavours via `spec.flavours[]` array
- If not specified, operator uses flavours with `enabledByDefault: true`
- Multiple flavours can be enabled simultaneously
```

#### 4. **Consequences**
```markdown
## Consequences

### Positive
✅ [Benefit 1]
✅ [Benefit 2]

### Negative
❌ [Trade-off 1]
❌ [Trade-off 2]

### Neutral
⚖️ [Neutral consequence 1]
```

**What to include:**
- **Positive**: Benefits and improvements
- **Negative**: Costs, limitations, technical debt
- **Neutral**: Notable impacts that are neither good nor bad

**Tips:**
- Be honest about trade-offs
- Every decision has consequences - don't skip negative ones
- Helps future readers understand what was sacrificed
- Use emojis (✅ ❌ ⚖️) for visual scanning

**Example:**
```markdown
## Consequences

### Positive
✅ Simplified onboarding for common use cases
✅ Flexible - combine flavours with CR overrides
✅ Maintainable - flavours versioned with operator

### Negative
❌ Coordination required between operator and domain teams
❌ Additional complexity in configuration resolution

### Neutral
⚖️ Backward compatible - no impact on existing CRs
⚖️ Optional feature - users can disable all flavours
```

### Optional Sections

#### **Alternatives Considered**

Use this section when you evaluated multiple approaches:

```markdown
## Alternatives Considered

### Alternative 1: [Name]
- **Approach**: [What it was]
- **Rejected because**: [Why not chosen]

### Alternative 2: [Name]
- **Approach**: [What it was]
- **Rejected because**: [Why not chosen]
```

**When to include:**
- Multiple viable solutions were discussed
- Team debated different approaches
- Future readers might wonder "why not X?"

**When to skip:**
- Only one obvious solution
- Alternatives were clearly inferior
- Decision was straightforward

#### **Implementation** (for detailed technical ADRs)

Use this for specific implementation details:

```markdown
## Implementation

### File Structure
[Show directory layout]

### API Design
[Show API/config format]

### Operator Behavior
[Describe how operator processes this]
```

**When to include:**
- Decision needs specific technical details
- Implementation approach is complex
- File/directory structure matters

**When to skip:**
- Implementation is straightforward
- Details belong in separate implementation docs
- Decision can be understood without implementation details

#### **Usage Examples**

Show concrete examples of how the decision works in practice:

```markdown
## Usage Examples

### Example 1: [Scenario]
[Code/config example]

**Result**: [What happens]

### Example 2: [Another scenario]
[Code/config example]

**Result**: [What happens]
```

**When to include:**
- Decision affects user-facing APIs or configuration
- Examples make the decision clearer
- Multiple use cases need illustration

## ADR Lifecycle (GitHub PR Workflow)

ADRs follow the standard GitHub PR workflow for review and approval. The PR state **is** the ADR status:
- **Open PR** = Proposed (under discussion)
- **Merged PR** = Accepted (immutable)
- **Closed PR** (not merged) = Rejected

### 1. **Creating an ADR** → Open PR

```bash
# Create a feature branch
git checkout -b adr/flavor-multi-tenancy

# Copy the template
cp ADR-TEMPLATE.md decisions/ADR-multi-tenancy.md

# Write your ADR
# Fill in: Context, Decision, Consequences, etc.

# Commit and push
git add decisions/ADR-multi-tenancy.md
git commit -m "ADR: Multi-tenancy support for flavours"
git push origin adr/flavor-multi-tenancy

# Open PR
gh pr create --title "ADR: Multi-tenancy support for flavours" \
  --body "Proposing architecture decision for multi-tenancy. Please review."
```

**PR Title Format**: `ADR: [Short Title]`

### 2. **Reviewing an ADR** → PR Comments & Reviews

**Review process:**
- Team members comment on specific sections
- Request changes for unclear reasoning
- Suggest alternatives not considered
- Challenge assumptions in Context
- Question trade-offs in Consequences

**Author responsibilities:**
- Address feedback by updating the ADR
- Add alternatives raised during review
- Refine rationale based on discussion
- Push updates to the same branch/PR

**Tips:**
- Use PR line comments for specific feedback
- Use PR general comments for overall direction
- Mark conversations as resolved when addressed
- Request re-review after updates

### 3. **Accepting an ADR** → PR Approval & Merge

**When ready to finalize:**
1. Team approves the PR (minimum approvals per your repo policy)
2. Merge the PR

```bash
# Merge the PR
gh pr merge --squash  # or --merge, per your repo policy
```

**Result:**
- ADR is now in main branch (accepted and immutable)
- Implementation can begin
- PR provides permanent discussion history

**Timeline:**
```
PR Open (proposed)
    ↓
PR Review & Discussion
    ↓
    ├─→ PR Approved & Merged (accepted, immutable)
    └─→ PR Closed without merge (rejected)
```

### 4. **Updating an Accepted ADR**

ADRs are **immutable** once merged. For changes:

#### **Minor clarifications:**
Open a PR that adds a note to the existing ADR without changing the original decision.

```markdown
## Notes

**2026-04-15**: During implementation, we discovered that X requires Y.
This doesn't change the decision but adds context.
```

#### **Major changes:**
Create a **new ADR**. The new ADR can reference the previous one for context.

```bash
git checkout -b adr/flavor-multi-tenancy-v2
cp ADR-TEMPLATE.md decisions/ADR-multi-tenancy-v2.md
# Write new ADR, optionally referencing the previous ADR for context
git commit -m "ADR: Multi-tenancy v2"
# Open PR
```

## Best Practices

### ✅ Do:

- **Write for future readers** - assume they don't know the context you have today
- **Be specific** - use concrete examples, not abstract concepts
- **Be honest** - document trade-offs and limitations
- **Keep it concise** - aim for 1-2 pages for simple decisions
- **Use simple language** - avoid jargon when possible

### ❌ Don't:

- **Write a novel** - ADRs should be scannable
- **Hide trade-offs** - be honest about downsides
- **Skip alternatives** - helps explain why you chose this approach
- **Change accepted ADRs** - create new ADR instead
- **Write implementation docs** - ADR is about the decision, not all the details

## Questions?

If unsure whether to write an ADR, ask:
1. Will someone in 6 months wonder why we did this?
2. Did we debate alternatives or make trade-offs?
3. Does this affect how other teams work?

If yes to any → write an ADR.

---

**Remember**: An ADR doesn't need to be perfect. Better to have a simple ADR than no ADR at all!