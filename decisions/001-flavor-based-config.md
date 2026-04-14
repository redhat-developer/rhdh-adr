# ADR: Flavour-Based Configuration for Backstage (RHDH) Operator

## Context

**Problem**: Users cannot easily deploy RHDH instances with common patterns (Orchestrator-enabled, AI-enabled, etc.) without writing complex Custom Resource specifications or modifying operator-level settings.

The RHDH Operator currently provides default configurations via ConfigMaps, but deploying instances with common patterns requires significant manual configuration. Users must either write complex Custom Resource specifications or modify operator-level settings, forcing configuration duplication across similar instances.

**Who is impacted**:
- Platform teams deploying multiple RHDH instances with similar configurations
- Users wanting to quickly deploy instances with common patterns (AI, orchestration, etc.)
- New users who need pre-configured starting points

**Constraints**:
- Must maintain backward compatibility with existing deployments
- Should leverage existing default-config infrastructure
- Must support multiple flavour combinations
- Configuration merge behavior must be predictable

## Decision

Implement **Flavour-Based Configuration** for the RHDH Operator, enabling lightweight deployment of pre-configured Backstage instances through a `spec.flavours[]` array specification.

Flavours function as configuration variations that extend the base default configuration rather than independent systems. Users can enable multiple flavours simultaneously, combine them, or disable all flavours to use only base defaults.

**Implementation approach**:
- **Nested structure**: Flavours reside in `/default-config/flavours/<flavour-name>/` within existing default-config infrastructure
- **Multi-flavour support**: Array-based specification (`spec.flavours[]`) enables multiple flavours with explicit merge ordering
- **Metadata-driven defaults**: Each flavour contains `metadata.yaml` with `enabledByDefault` flag to reduce configuration burden
- **Automatic fallback**: Unmapped configuration files automatically revert to base defaults
- **Type-specific merging**: Different merge strategies for Kubernetes objects (kyaml deep merge), dynamic plugins (array merge by package name), and app configs (multiple file mounts)
- **Initial flavours**: `orchestrator` (Tekton/ArgoCD, disabled by default) and `lightspeed` (AI/ML, enabled by default)

**Example usage**:
```yaml
apiVersion: rhdh.redhat.com/v1alpha6
kind: Backstage
metadata:
  name: my-backstage
spec:
  flavours:
    - name: orchestrator
      enabled: true
    - name: lightspeed
      enabled: true
```

## Design Decisions

### Decision 1: Flavours as Variations of Default Config

**Chosen:** Flavours nested within default-config emphasize their nature as extensions rather than alternatives.

**Rationale:**
- Leverages existing infrastructure
- Maintains backward compatibility
- Clear fallback behavior to base defaults
- Minimal code changes required

### Decision 2: Multi-Flavour Support

**Chosen:** Array-based multi-flavour support enables selective enablement/disablement and explicit merge ordering.

**Rationale:**
- Accommodates complex feature combinations
- Users can combine multiple patterns (e.g., both AI and Orchestrator)
- Clear merge order through specification sequence

### Decision 3: Metadata-Driven Defaults

**Chosen:** Each flavour contains `metadata.yaml` with `enabledByDefault` flag.

**Rationale:**
- Reduces configuration burden
- Allows explicit override when needed
- Co-located with flavour definition

## Implementation

### Configuration Merge Strategies

Different file types employ type-specific merging:

- **Kubernetes objects:** kyaml deep merge preserving additive configurations
- **dynamic-plugins.yaml:** Array merge by package name with override capability
- **app-config.yaml:** Multiple files mounted for Backstage internal merging
- **Extra config:** multiple ConfigMaps/Secrets as defined

## Usage Examples

### Example 1: Default Behavior

```yaml
apiVersion: rhdh.redhat.com/v1alpha6
kind: Backstage
metadata:
  name: my-backstage
spec:
  # No flavours specified
```

**Result:** Automatic enablement of `enabledByDefault: true` flavours (Lightspeed).

### Example 2: Multi-Flavour Enablement

```yaml
apiVersion: rhdh.redhat.com/v1alpha6
kind: Backstage
metadata:
  name: my-backstage
spec:
  flavours:
    - name: orchestrator
      enabled: true
    - name: lightspeed
      enabled: true
```

**Result:** Configurations merge in specification order with later entries overriding earlier ones.

### Example 3: Disable All Flavours

```yaml
apiVersion: rhdh.redhat.com/v1alpha6
kind: Backstage
metadata:
  name: my-backstage
spec:
  flavours: []
```

**Result:** Uses only base default configuration.

## Consequences

### Positive

✅ Simplified onboarding through pre-configured patterns
✅ Flexible combination with CR overrides
✅ Versioned with operator releases
✅ Backward compatible with existing deployments

### Negative

❌ Merge complexity requires careful flavour design
❌ Authors must document incompatibilities
❌ Cross-team coordination necessary

### Neutral

⚖️ Optional feature - users can disable all flavours
⚖️ Easily extensible for future flavours

## History

### 2026-01-23 - Multi-flavour Support
- Multi-flavour support with file-type-specific merge strategies adopted
- Array-based specification for selective enablement

### 2026-01-15 - Initial Draft
- Initial single-flavour selection proposed
