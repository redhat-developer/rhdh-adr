# Using AI to Write ADRs

A practical guide for using AI to help draft and refine Architecture Decision Records.

## Quick Workflow

```
1. Brain dump your problem → AI structures it
2. AI generates draft ADR → You add project context
3. AI suggests alternatives → You validate feasibility
4. AI critiques draft → You refine
5. Team reviews on PR → Final decision (most important!)
```

**Remember:** AI helps draft, humans decide. Team review is mandatory.

## Using Claude Code Skills (Recommended)

**If you're using Claude Code CLI**, this repository has a custom `/adr` skill that automates the workflow below:

- `/adr structure` - Structure a problem into ADR format (Phase 1)
- `/adr draft` - Generate complete ADR draft (Phase 2)
- `/adr alternatives` - Suggest alternative approaches (Phase 3)
- `/adr critique` - Review and strengthen your ADR (Phase 4)
- `/adr refine` - Improve specific sections (Phase 5)

**Example:**
```bash
/adr critique decisions/001-flavor-based-config.md
```

The skill automatically reads ADR-TEMPLATE.md and ADR-GUIDE.md, understands the RHDH context, and provides structured feedback.

**If you're not using Claude Code**, use the manual prompt templates below instead.

---

## Phase 1: Initial Problem Structuring

**Use when:** You have a messy problem and need to organize thoughts.

### Prompt Template
```
I need to write an ADR for [project-name].

Project context:
- Repository: [URL to public repo]
- What it is: [Brief description of what the project does]

First, read:
- ADR-GUIDE.md (to understand our ADR structure)
- ADR-TEMPLATE.md (for the template format)

Here's the problem:

[Describe the problem, current state, and what's not working]

Help me structure this into an ADR format following our guide. What should I include in:
- Context section
- Decision options to consider
- Key trade-offs to analyze
```

### Example
```
I need to write an ADR for the rhdh-operator project.

Project context:
- Repository: https://github.com/redhat-developer/rhdh-operator
- What it is: Kubernetes operator for deploying Red Hat Developer Hub/Backstage instances

First, read:
- ADR-GUIDE.md (to understand our ADR structure)
- ADR-TEMPLATE.md (for the template format)

Here's the problem:

We have ConfigMaps in /default-config but no way to provide secrets for
default configs. Users duplicate secrets across instances. Need a way to
share common credentials (DB passwords, API tokens) across Backstage instances
in the same namespace.

Help me structure this into an ADR format following our guide. What should I include in:
- Context section
- Decision options to consider
- Key trade-offs to analyze
```

## Phase 2: Draft Generation

**Use when:** You know what you want to do, need it formatted as ADR.

### Prompt Template
```
Generate an ADR draft using our template (ADR-TEMPLATE.md).

Project context:
- Repository: [URL to public repo]
- What it is: [Brief description of what the project does]

Decision: [What you've decided to do]

Context:
- Current state: [What exists now]
- Problem: [What's broken/missing]
- Requirements: [What must be true]

Please fill in:
- Context section explaining the problem
- Decision section with implementation approach
- Alternatives we should consider
- Consequences (positive and negative)
```

### Example
```
Generate an ADR draft using our template (ADR-TEMPLATE.md).

Project context:
- Repository: https://github.com/redhat-developer/rhdh-operator
- What it is: Kubernetes operator for deploying Red Hat Developer Hub/Backstage instances

Decision: Introduce label-based discovery of secrets in the Backstage CR's
namespace. Secrets labeled with rhdh.redhat.com/default-config are discovered
and injected as env vars.

Context:
- Current state: Default configs from /default-config in operator pod
- Problem: No way to include secrets in default configs
- Requirements: Must work with existing RBAC, namespace-scoped

Please fill in:
- Context section explaining the problem
- Decision section with implementation approach
- Alternatives we should consider
- Consequences (positive and negative)
```

## Phase 3: Alternative Exploration

**Use when:** You want to ensure you've considered all options.

### Prompt Template
```
Review this ADR decision:

[Paste your Decision section]

What are 3-4 alternative approaches we should consider? For each:
- How would it work?
- What are the trade-offs vs. our chosen approach?
- Why might someone prefer it?
```

### Devil's Advocate Variant
```
Play devil's advocate on this ADR decision:

[Paste your full ADR]

What are the strongest arguments AGAINST this approach?
What edge cases or problems might we encounter?
```

## Phase 4: Gap Analysis

**Use when:** You want to strengthen your ADR before team review.

### Prompt Template
```
Critique this ADR draft:

[Paste your ADR]

What's missing or unclear in:
- Context: Is the problem well-explained?
- Decision: Is the approach clear and specific?
- Alternatives: What obvious options are missing?
- Consequences: What trade-offs are we not acknowledging?
```

### Technical Validation Prompt
```
Review this technical decision for the rhdh-operator (Kubernetes operator):

[Paste Decision section]

Questions:
- Does this approach make sense for a Kubernetes operator?
- Are there Kubernetes-native patterns we should use instead?
- What implementation challenges might arise?
- What are we not considering?
```

## Phase 5: Refinement

**Use when:** Improving specific sections.

### Shorten/Clarify Prompt
```
This Context section is too long or unclear:

[Paste Context section]

Rewrite it to be:
- More concise (under 3 paragraphs)
- Clearer about the core problem
- Focused on "why" we need to decide
```

### Consequences Check
```
Review the Consequences section:

[Paste Consequences section]

Are we being honest about trade-offs?
What negative consequences are missing?
Are the positive consequences realistic?
```

## Phase 6: Using Project Context

**Use when:** AI needs to understand your specific codebase.

### Provide Context Prompt
```
I'm working on the rhdh-operator project. Here are relevant files:

[Use Claude Code to read relevant files]

Given this context, review my ADR:

[Paste ADR]

Does the decision fit with existing patterns in the codebase?
Are there existing mechanisms we should reuse?
```

### Example with File Reading
```
Read these files to understand our current config system:
- pkg/model/runtime.go (how we load configs)
- docs/configuration.md (config documentation)

Now review this ADR for namespaced config discovery:

[Paste ADR]

Does this align with existing patterns?
What implementation details should I clarify?
```

## Quick Tips

**Do:**
- ✅ Start with rough ideas, let AI structure
- ✅ Ask AI to critique and find gaps
- ✅ Use AI to generate alternatives you might miss
- ✅ Validate all AI suggestions against your actual codebase
- ✅ Add project-specific context AI can't know

**Don't:**
- ❌ Accept AI alternatives without checking feasibility
- ❌ Skip team review because "AI reviewed it"
- ❌ Use AI-generated technical details without verification
- ❌ Let AI make the decision (you decide, AI helps draft)

**Critical Checkpoint:**
Before opening PR, verify:
- [ ] Alternatives are actually feasible for your project
- [ ] Technical details match your codebase
- [ ] Context includes team/project-specific constraints AI wouldn't know
- [ ] Consequences are honest about trade-offs
- [ ] You understand and can defend every part of the ADR

## Iteration Pattern

Effective ADR creation with AI is iterative:

```
You: "Here's my problem" → AI: "Here's a structure"
You: "Draft an ADR" → AI: "Here's a draft"
You: "What's missing?" → AI: "Consider these gaps"
You: "Critique this" → AI: "Here are weaknesses"
You: "Refine section X" → AI: "Here's an improvement"
You: Validate, add context, finalize
```

Typically 3-5 iterations to get a solid draft ready for team review.

---

**Remember:** AI accelerates drafting, team review drives decision. The PR discussion is where the real decision happens.
