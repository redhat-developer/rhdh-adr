---
name: adr
description: Architecture Decision Record assistant for rhdh-adr repository
---

# ADR Skill

Help write, review, and refine Architecture Decision Records for RHDH projects.

## Available Commands

- `/adr structure` - Structure a messy problem into ADR format
- `/adr draft` - Generate complete ADR from your decision
- `/adr critique` - Review and critique an existing ADR
- `/adr alternatives` - Suggest alternative approaches
- `/adr refine` - Improve a specific ADR section

## Command Details

### /adr structure

Help structure a problem into ADR format.

**Process:**
1. Ask user: "What problem are you solving? What's the current state and limitation?"
2. Optionally ask for project context if needed: "What's your project repository URL and what does it do?"
3. Read `ADR-TEMPLATE.md` to understand structure
4. Analyze the problem and suggest:
   - How to frame the Context section
   - What decision options to consider
   - Key trade-offs to analyze
   - What information is missing

**Output:** Structured outline ready to fill into template

---

### /adr draft

Generate a complete ADR draft from a decision.

**Process:**
1. Ask user for:
   - What decision have you made?
   - What problem does it solve?
   - Current state/limitations
   - Key requirements or constraints
2. Optionally ask for project context if needed: "What's your project repository URL and what does it do?"
3. Read `ADR-TEMPLATE.md` for structure
4. Read `ADR-GUIDE.md` for guidelines
5. Generate complete ADR including:
   - **Title**: Short, descriptive (5-10 words)
   - **Context**: Problem statement, who's affected, constraints
   - **Decision**: Clear statement + implementation approach
   - **Alternatives Considered**: 3-4 realistic alternatives with rejection rationale
   - **Consequences**: Honest positive ✅, negative ❌, and neutral ⚖️ impacts

**Output:** Complete ADR ready for review and PR

---

### /adr critique

Critique an existing ADR draft to strengthen it.

**Process:**
1. Ask user: "Provide the ADR file path or paste the content"
2. If file path given, read the file
3. Read `ADR-GUIDE.md` for quality criteria
4. Analyze:
   - **Context**: Is problem clear? Is "why decide now" explained?
   - **Decision**: Is it specific and actionable? Clear implementation approach?
   - **Alternatives**: Are they realistic? Is rejection rationale sound?
   - **Consequences**: Are trade-offs honest? Missing negative impacts?
   - **Overall**: What's missing, unclear, or weak?
5. Provide specific improvement suggestions

**Output:** Critique with actionable improvements

---

### /adr alternatives

Suggest alternative approaches and play devil's advocate.

**Process:**
1. Ask user: "What's your current decision or approach?"
2. If they reference an existing ADR, read it
3. Generate 3-4 alternative approaches:
   - How each would work
   - Trade-offs vs chosen approach
   - When someone might prefer it
   - Why it might be better/worse
4. Play devil's advocate: strongest arguments AGAINST the chosen approach
5. Identify edge cases or problems

**Output:** Comprehensive alternatives analysis

---

### /adr refine

Improve a specific section of an ADR.

**Process:**
1. Ask user: "Which section do you want to refine? (Context, Decision, Alternatives, Consequences)"
2. Ask: "Paste the current content or provide ADR file path"
3. Read `ADR-GUIDE.md` for section-specific guidance
4. Improve the section to be:
   - More concise (if too long)
   - Clearer (if ambiguous)
   - More specific (if too vague)
   - More honest (if hiding trade-offs)
5. Ensure format follows template requirements

**Output:** Refined section ready to use

---

## Context & Guidelines

**Project:** RHDH (Red Hat Developer Hub) - Kubernetes operator and related components

**Repository Structure:**
```
rhdh-adr/
├── ADR-TEMPLATE.md       # Template to follow
├── ADR-GUIDE.md          # Writing guidelines
├── ADR-AI-GUIDE.md       # AI assistance guide
└── decisions/            # Actual ADRs
    ├── 001-flavor-based-config.md
    └── 002-plugin-infrastructure.md
```

**Key Principles:**
- **PR Workflow**: PR state is the status (Open = Proposed, Merged = Accepted, Closed = Rejected)
- **Honesty**: Be explicit about trade-offs (don't hide negatives)
- **Alternatives**: Consider Kubernetes-native patterns, operator best practices
- **Context**: Focus on "why" we need to decide, not "what" the decision is
- **Consequences**: Use ✅ ❌ ⚖️ for visual scanning
- **Team Review**: ADR is a draft tool, team PR review makes final decision

**Technical Context:**
- Kubernetes operator development (controller-runtime, operator-sdk)
- OpenShift compatibility required
- RHDH-specific: flavours, dynamic plugins, default configurations

**Common Patterns to Consider:**
- ConfigMap/Secret-based configuration
- Label/annotation-based discovery
- CRD design and versioning
- Operator reconciliation patterns
- Multi-tenancy considerations

---

## Usage Examples

### Example: Structuring a Problem

**User:** `/adr structure`

**Claude:** "What problem are you solving? What's the current state and limitation?"

**User:** "We can't share secrets across Backstage instances. Users duplicate secrets in every CR."

**Claude:** [Reads ADR-TEMPLATE.md, provides structured outline]

---

### Example: Drafting an ADR

**User:** `/adr draft`

**Claude:** "What decision have you made? What problem does it solve?"

**User:**
```
Decision: Label-based secret discovery in namespace
Problem: No way to share common credentials across Backstage instances
Current state: Each CR must specify secrets individually
```

**Claude:** [Reads ADR-TEMPLATE.md and ADR-GUIDE.md, generates complete ADR]

---

### Example: Critiquing

**User:** `/adr critique decisions/003-namespaced-config.md`

**Claude:** [Reads file and ADR-GUIDE.md, provides critique]
```
Critique of ADR-003:

Context section:
✅ Clear problem statement
❌ Missing: Why is duplication specifically a problem? (ops burden? consistency?)

Decision section:
✅ Specific implementation approach
⚠️ Consider clarifying: What happens if labeled secret doesn't exist?

Alternatives section:
❌ Missing: Operator-namespace approach (cluster-wide defaults)
❌ Missing: External secret management (e.g., Vault)

Consequences:
✅ Good positive list
❌ Negative list incomplete - missing: namespace coupling, RBAC complexity
```

---

## Tips for Best Results

**Do:**
- Be specific about your problem and constraints
- Mention technical context (Kubernetes, operator patterns, etc.)
- Reference existing ADRs if related: "similar to ADR-001 but for..."
- Ask for critique even if you think it's complete

**Don't:**
- Ask AI to make the decision (you decide, AI helps draft)
- Skip validation of AI-suggested alternatives against your codebase
- Skip team PR review because "AI reviewed it"

**Iteration Pattern:**
Most effective ADRs come from 3-5 iterations:
1. `/adr structure` → outline
2. `/adr draft` → initial version
3. `/adr critique` → identify gaps
4. `/adr refine` → improve weak sections
5. `/adr alternatives` → ensure completeness
6. **Human team review on PR** → final decision

---

## Integration with Workflow

This skill integrates with the ADR lifecycle documented in `ADR-GUIDE.md`:

```
1. `/adr draft` → Generate initial ADR
2. Open PR with ADR (Open PR = Proposed)
3. `/adr critique` → Strengthen before team review
4. Team reviews PR, comments
5. `/adr refine` → Address feedback
6. PR approved & merged → ADR finalized (Merged PR = Accepted)
```

**Remember:** The skill accelerates drafting. Team PR review is where the real architectural decision happens.
