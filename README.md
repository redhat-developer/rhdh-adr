# RHDH Architecture Decision Records

Architecture decisions for Red Hat Developer Hub (RHDH) projects.

## Quick Start

### Writing an ADR

1. **Read the guide first**: [ADR-GUIDE.md](ADR-GUIDE.md)
2. **Use the template**: [ADR-TEMPLATE.md](ADR-TEMPLATE.md)
3. **Optional - AI assistance**: [ADR-AI-GUIDE.md](ADR-AI-GUIDE.md) (includes Claude Code `/adr` skill)

### Workflow

```bash
# Copy template
cp ADR-TEMPLATE.md decisions/ADR-my-decision.md

# Edit and fill in the template

# Open PR for review
git checkout -b adr/my-decision
git add decisions/ADR-my-decision.md
git commit -m "ADR: My architectural decision"
git push origin adr/my-decision

# After approval and merge, ADR is accepted
```

## Resources

- **[ADR-TEMPLATE.md](ADR-TEMPLATE.md)** - Copy this to start a new ADR
- **[ADR-GUIDE.md](ADR-GUIDE.md)** - Complete guide for writing ADRs
- **[ADR-AI-GUIDE.md](ADR-AI-GUIDE.md)** - Using AI to help draft ADRs
- **[decisions/](decisions/)** - All accepted ADRs

## ADR Lifecycle

ADRs follow GitHub PR workflow. **The PR state IS the status** - no status field in the ADR file.

- **PR Open** → Proposed (under discussion)
- **PR Merged** → Accepted (immutable)
- **PR Closed** (not merged) → Rejected

**Workflow:**
1. Write ADR, open PR
2. Team reviews and discusses on PR
3. Merge PR when approved (ADR is now accepted)

See [ADR-GUIDE.md](ADR-GUIDE.md#adr-lifecycle-github-pr-workflow) for details.

## When to Write an ADR

Write an ADR when making decisions that:

✅ Affect multiple components or teams
✅ Have long-term impact
✅ Are difficult to reverse
✅ Involve trade-offs
✅ Need team alignment

See [ADR-GUIDE.md](ADR-GUIDE.md#when-to-write-an-adr) for more guidance.

## Contributing

1. Fork this repository
2. Create a branch: `git checkout -b adr/your-decision`
3. Write your ADR in `decisions/`
4. Open a PR for team review (PR open = Proposed)
5. After approval, merge the PR (PR merged = Accepted)

## About ADRs

Architecture Decision Records capture important architectural decisions along with their context and consequences. They help teams:

- Document **why** decisions were made
- Prevent revisiting settled decisions
- Onboard new team members
- Create institutional memory

Learn more: [ADR-GUIDE.md](ADR-GUIDE.md)
