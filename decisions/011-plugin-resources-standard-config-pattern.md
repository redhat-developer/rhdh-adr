# ADR: Plugin Resources Standard Configuration Pattern

## Context

**Problem**: Plugin dependencies use a special `plugin-deps/` directory with file prefix matching for resource selection, creating an inconsistent configuration pattern compared to other operator resources and limiting flavour support.

**Current state:**
- Plugin dependency resources stored in dedicated `plugin-deps/` directory
- Resources selected by file prefix matching on dependency ref (e.g., `tekton` matches `tekton*.yaml`)
- Template variable format uses `{{backstage-name}}` instead of standard Go template syntax
- Cannot override plugin resources per flavour
- Special-case code path separate from other operator resources
- Resources scattered across multiple files in directory

**Who is impacted:**
- **Operators/SREs**: Managing plugin dependencies requires understanding special directory structure and prefix matching logic
- **Flavour authors**: Cannot customize plugin resources for specific flavours (e.g., different Tekton tasks for orchestrator flavour)
- **Plugin developers**: Must learn non-standard configuration pattern for plugin dependencies
- **Platform teams**: Inconsistent patterns increase cognitive load and maintenance burden

**Constraints:**
- Must maintain backward compatibility during migration
- Must preserve existing plugin dependency behavior (resources follow plugin enabled/disabled state)
- Selection mechanism must support exact matching to avoid ambiguity
- Must integrate with existing flavour system (ADR-001)

## Decision

Replace the `plugin-deps/` directory mechanism with standard default-config/flavour configuration pattern, using labeled resources in `plugin-resources.yaml` files with exact label matching.

**Implementation approach:**

1. **Standard config location**:
   - Move from `plugin-deps/*.yaml` → `default-config/plugin-resources.yaml`
   - Flavour overrides in `default-config/flavours/<flavour-name>/plugin-resources.yaml`
   - Single multi-document YAML file per location (base + each flavour)

2. **Label-based selection**:
   - Required labels on all plugin resources:
     - `rhdh.redhat.com/plugin: <plugin-name>` - Plugin identifier
     - `rhdh.redhat.com/ref: <ref-name>` - Dependency reference name
   - Optional annotation for additional image dependencies:
     - `rhdh.redhat.com/additional-images: '["image1:tag", "image2:tag"]'` - JSON array of container images not directly visible in manifest (e.g., created by operators from CRs, indirect dependencies)
   - Exact label matching replaces file prefix matching
   - Eliminates ambiguity and prevents accidental matches

3. **Template variable standardization**:
   - Replace `{{backstage-name}}` with standard Go template `{{.Rhdh.Name}}`
   - Consistent with other operator resource templates
   - Enables full Go template functionality

4. **Flavour merge semantics**:
   - Base resources loaded from `default-config/plugin-resources.yaml`
   - Flavour resources override base for same (plugin, ref) combination
   - Follows standard resource merge pattern (base → flavours)

5. **RuntimeObject implementation**:
   - New RuntimeObject: `PluginDependencies`
   - Config key: `plugin-resources.yaml`
   - Load and merge from base + active flavours
   - Apply resources where (plugin, ref) matches dependency list in plugin config

**Example transformation:**

**Before:**
```yaml
# plugin-deps/sonataflow.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-{{backstage-name}}
spec:
  template:
    spec:
      containers:
        - name: setup
          image: postgres:15

---
# plugin-deps/tekton.yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: workflow-task-{{backstage-name}}
```

**After:**
```yaml
# default-config/plugin-resources.yaml
---
apiVersion: batch/v1
kind: Job
metadata:
  name: db-{{.Rhdh.Name}}
  labels:
    rhdh.redhat.com/plugin: orchestrator
    rhdh.redhat.com/ref: sonataflow
spec:
  template:
    spec:
      containers:
        - name: setup
          image: postgres:15
---
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: workflow-task-{{.Rhdh.Name}}
  labels:
    rhdh.redhat.com/plugin: orchestrator
    rhdh.redhat.com/ref: tekton
  annotations:
    rhdh.redhat.com/additional-images: '["quay.io/tekton/operator-controller:v0.68.0"]'
```

**Flavour override example:**
```yaml
# default-config/flavours/orchestrator/plugin-resources.yaml
---
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: workflow-task-{{.Rhdh.Name}}
  labels:
    rhdh.redhat.com/plugin: orchestrator
    rhdh.redhat.com/ref: tekton
spec:
  # Orchestrator flavour-specific task configuration
  steps:
    - name: custom-step
      image: custom-image:latest
```

**Resource selection:**
```yaml
# Plugin config specifying dependencies
plugins:
  - package: ref://orchestrator
    enabled: true
    dependencies:
      - ref: tekton      # Matches plugin=orchestrator, ref=tekton
      - ref: sonataflow  # Matches plugin=orchestrator, ref=sonataflow
```

## Migration Path

1. **Phase 1: Add new system**
   - Implement PluginDependencies RuntimeObject
   - Add plugin-resources.yaml to default-config
   - Add required labels to all resources
   - Update template variables to Go template syntax
   - Both systems coexist

2. **Phase 2: Migration**
   - Migrate all plugin-deps resources to plugin-resources.yaml
   - Test flavour override functionality
   - Verify resource selection works correctly

3. **Phase 3: Cleanup**
   - Remove plugin-deps directory
   - Delete plugin-deps code path
   - Update documentation

## Consequences

### Positive

✅ **Standard config pattern**: No special directory, same pattern as other operator resources
✅ **Flavour support**: Plugin resources can be overridden per flavour (orchestrator, lightspeed, etc.)
✅ **Better discoverability**: Single file vs. scattered directory makes resources easier to find
✅ **Exact matching**: Label-based selection eliminates ambiguity from prefix matching
✅ **Template consistency**: Standard Go template syntax across all operator resources
✅ **Reduced cognitive load**: One configuration pattern to learn instead of multiple special cases
✅ **Air-gap support**: Additional images annotation enables automated discovery of indirect dependencies for disconnected environments
✅ **Path to catalog-based config**: Opens way to define dependencies in catalog (like plugins), moving plugin configuration ownership out of operator code
✅ **Simpler testing**: Single file easier to validate and test than directory of files

### Negative

❌ **Breaking change**: Existing plugin-deps configurations won't work without migration (requires operator-team migration effort)

### Neutral

⚖️ **ConfigMap size**: Single multi-document YAML may increase ConfigMap size slightly

## Notes

**Related ADRs:**
- ADR-001 (Flavour-Based Configuration): Provides flavour infrastructure this integrates with
- ADR-002 (DevHubPluginCatalog CRD): Catalog system that defines plugins
- ADR-003 (Operator-Based Plugin Configuration Processing): Plugin config processing that references dependencies

**Implementation details:**
- Resource selection: Filter resources by exact label match where `plugin` matches enabled plugin and `ref` is in plugin's dependency list
- Merge strategy: Later flavours override earlier ones for same (plugin, ref) combination
- Template context: Full operator template context available (`.Rhdh`, `.Values`, etc.)
- Additional images: Optional `rhdh.redhat.com/additional-images` annotation declares container images not directly visible in manifests (e.g., created by operators from CRs). Used for air-gap image discovery (see ADR-012).

**Future considerations:**
- Catalog-based dependency definition: Move dependency specifications from operator code to catalog entries, same way as for other part of plugin
