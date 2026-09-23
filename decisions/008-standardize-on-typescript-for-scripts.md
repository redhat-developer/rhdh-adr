# ADR: Standardize on TypeScript for Scripts and Tooling

## Context

**Problem**: Scripts and tooling across RHDH repositories use an inconsistent mix of Bash, Python, and JavaScript/TypeScript, increasing cognitive load and reducing code quality.

Over time, RHDH repositories have accumulated scripts in multiple languages without a deliberate choice of which to use when. The result is a fragmented codebase where:
- Bash scripts have grown to 1000+ lines (e.g., the sync-midstream script), well past the point of reasonable readability or testability
- Python appears in places like the init container sidecar, chosen for expedience during early development rather than strategic fit
- JavaScript and TypeScript are used in other places, but without a clear mandate to prefer them

This inconsistency affects the team in several ways:
- Contributors must context-switch between languages, linting rules, and testing approaches
- Bash and Python scripts lack the type safety that catches bugs early — a wrong variable name in a shell script silently breaks things
- Scripts cannot easily share code with the CLI or other TypeScript tooling, even when they solve overlapping problems (e.g., dynamic plugin installation logic used by both the init container and potential CLI dev commands)
- Reviewing and maintaining scripts in less-familiar languages is slower and more error-prone

**Who is impacted**:
- Contributors writing or maintaining scripts, CI pipelines, and container entrypoints
- Teams building the RHDH CLI, who could benefit from shared logic with scripts and tooling
- Anyone debugging failures in long, untyped shell scripts

**Constraints**:
- Not all environments have Node.js available (e.g., a future standalone init container for dynamic plugins)
- Existing scripts should not require an immediate rewrite — bandwidth is limited
- The operator is in Go and Helm charts are YAML; this decision applies to scripting, not those domains

## Decision

Standardize on **TypeScript** as the default language for scripts and tooling across RHDH, in any environment where Node.js is already available.

Node.js can [execute TypeScript files directly](https://nodejs.org/learn/typescript/run-natively) through built-in type stripping — no transpilation step, no additional dependencies, no build tooling required. You point `node` at a `.ts` file and it runs. This makes TypeScript a practical replacement for Bash and Python in these contexts, with no added complexity to the execution environment.

**Implementation approach**:
- **New scripts**: All new scripts must be written in TypeScript where the runtime environment includes Node.js
- **Existing scripts**: Migrate to TypeScript incrementally using the boy scout rule — when a script needs modification or refactoring, convert it to TypeScript at that time
- **Environments without Node.js**: Where Node.js is not present, Bash is permitted for simple, short-lived scripts (e.g., container entrypoints, glue scripts). However, when a Bash script grows in complexity to the point where it becomes difficult to read, test, or maintain, Node.js should be introduced and the script rewritten in TypeScript. The maintainer of the script is trusted to identify when that threshold is reached
- **Testing**: New and converted TypeScript scripts should include tests using Node.js' [built-in test runner](https://nodejs.org/api/test.html), addressing a gap that most existing Bash and Python scripts have. The built-in test runner requires no additional dependencies — like TypeScript execution itself, it ships with Node.js. This keeps the toolchain minimal and avoids introducing external test frameworks for scripts that are meant to stay lightweight

## Alternatives Considered

### Alternative 1: Continue with mixed languages (status quo)
- **Approach**: Allow contributors to pick whatever language they prefer for each script
- **Rejected because**: This is the current state that caused the problems described in Context. The lack of consistency increases maintenance burden and prevents code sharing

### Alternative 2: Standardize on Python
- **Approach**: Use Python for all scripting since it is widely available and readable
- **Rejected because**: The RHDH product and its ecosystem (Backstage) are built on Node.js and TypeScript. Standardizing on Python would still require contributors to context-switch between the product language and the scripting language. TypeScript allows code sharing between scripts and the CLI/product code

### Alternative 3: Standardize on Bash for simplicity
- **Approach**: Keep all scripts in Bash to avoid introducing runtime dependencies
- **Rejected because**: Bash lacks type safety, has no practical testing story at scale, and becomes unreadable in scripts beyond a few hundred lines. The team has firsthand experience with 1000+ line Bash scripts that are difficult to maintain and debug

### Alternative 4: Mandate an immediate full rewrite of all scripts
- **Approach**: Convert all existing Bash and Python scripts to TypeScript in a dedicated effort
- **Rejected because**: The team does not have bandwidth for a large-scale rewrite, and the risk of introducing regressions outweighs the benefit. The boy scout rule provides a pragmatic migration path that spreads the work over time

## Consequences

### Positive
✅ Consistent language across scripts, CI tooling, and the product codebase reduces context-switching
✅ Type checking catches bugs that silently pass in Bash (e.g., misspelled variable names)
✅ Scripts become testable using Node.js' built-in test runner with no external dependencies
✅ Enables code sharing between scripts and the RHDH CLI (e.g., dynamic plugin installation logic)
✅ Leverages existing team expertise — the team primarily works in TypeScript

### Negative
❌ Environments where Node.js is not present cannot follow this standard and must use Bash, creating a (smaller) split
❌ The boy scout rule means inconsistency will persist for some time until scripts are naturally touched
❌ Contributors need to become familiar with TypeScript and its tooling conventions, which may require adjusting existing workflows
❌ Environments that do not already include a scripting runtime gain additional attack surface by introducing Node.js
❌ Adding Node.js to images that do not already include it increases their size and footprint

### Neutral
⚖️ Does not affect the operator (Go) or Helm charts (YAML) — scoped to scripting and tooling only
⚖️ No immediate migration work required; the change is forward-looking with gradual adoption
