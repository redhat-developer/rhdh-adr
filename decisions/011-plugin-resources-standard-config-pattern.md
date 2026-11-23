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
- Must preserve existing plugin dependency behavior (resources follow plugin enabled/disabled state)
- Selection mechanism must support exact matching to avoid ambiguity
- Must integrate with existing flavour system (ADR-001)

## Decision

Replace the `plugin-deps/` directory mechanism with standard default-config/flavour configuration pattern, using labeled resources in `plugin-resources.yaml` files with exact label matching.

**Key principle**: Plugin resources are configured separately from plugin definitions, requiring labels to match resources to plugin dependencies at runtime.

**Implementation approach:**

1. **Standard config location**:
   - Primary use: `default-config/flavours/<flavour-name>/plugin-resources.yaml` (flavour-specific resources)
   - Single multi-document YAML file per flavour
   - **Main pattern**: Plugin resources defined in flavours where plugins are actually enabled
   - Resources are stored in flavour files but matched to plugins via labels (not file location)

2. **Label-based selection**:
   - **Why labels are needed**: Resources are configured separately from plugin definitions, so we need a way to match resources to plugin dependencies at runtime
   - Required labels on all plugin resources:
     - `rhdh.redhat.com/plugin: <plugin-name>` - Identifies which plugin this resource belongs to (e.g., `red-hat-developer-hub-backstage-plugin-orchestrator-backend`)
     - `rhdh.redhat.com/ref: <ref-name>` - Identifies the specific dependency (e.g., `tekton`, `sonataflow`, `okp`)
   - **Unique matching**: Combination of `(plugin, ref)` is unique - e.g., `tekton` in context of `orchestrator` plugin
   - **Context-specific**: The same `ref` name (e.g., `tekton`) can mean different things for different plugins
   - Optional annotation for additional image dependencies:
     - `rhdh.redhat.com/additional-images: '["image1:tag", "image2:tag"]'` - JSON array of container images not directly visible in manifest (e.g., created by operators from CRs, indirect dependencies)
   - Exact label matching replaces file prefix matching

3. **Template variable standardization**:
   - Replace `{{backstage-name}}` with standard Go template `{{.Rhdh.Name}}`
   - Consistent with other operator resource templates
   - Enables full Go template functionality

4. **RuntimeObject implementation**:
   - New RuntimeObject: `PluginResources`
   - Config key: `plugin-resources.yaml`
   - Load resources from enabled flavours
   - Filter by exact label match: where `plugin` label matches enabled plugin and `ref` label is in plugin's dependency list
   - Apply matched resources
   - **Merge semantics**:
     - Resources: If multiple resources exist with the same `(plugin, ref)` combination, last one wins (no internal merge)
     - Dependencies list: Existing behavior unchanged - not defined means inherit, `dependencies: []` means clear

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

**After (label-based):**
```yaml
# default-config/flavours/orchestrator/plugin-resources.yaml
---
apiVersion: batch/v1
kind: Job
metadata:
  name: db-{{.Rhdh.Name}}
  labels:
    rhdh.redhat.com/plugin: red-hat-developer-hub-backstage-plugin-orchestrator-backend
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
    rhdh.redhat.com/plugin: red-hat-developer-hub-backstage-plugin-orchestrator-backend
    rhdh.redhat.com/ref: tekton
  annotations:
    rhdh.redhat.com/additional-images: '["quay.io/tekton/operator-controller:v0.68.0"]'
spec:
  steps:
    - name: orchestrator-step
      image: orchestrator-image:latest
```

**Resource selection:**
```yaml
# Plugin config specifying dependencies
plugins:
  - package: ref://red-hat-developer-hub-backstage-plugin-orchestrator-backend
    enabled: true
    dependencies:
      - ref: tekton      # Matches label: plugin=red-hat-developer-hub-backstage-plugin-orchestrator-backend, ref=tekton
      - ref: sonataflow  # Matches label: plugin=red-hat-developer-hub-backstage-plugin-orchestrator-backend, ref=sonataflow
```

## Consequences

### Positive

✅ **Standard config pattern**: No special directory, same pattern as other operator resources
✅ **Exact matching**: Label-based selection eliminates ambiguity from prefix matching
✅ **Context-specific dependencies**: Same `ref` name can mean different things for different plugins (e.g., `tekton` for orchestrator vs future `tekton` for other plugins)
✅ **Template consistency**: Standard Go template syntax across all operator resources
✅ **Reduced cognitive load**: One configuration pattern to learn instead of multiple special cases
✅ **Air-gap support**: Additional images annotation enables automated discovery of indirect dependencies for disconnected environments
✅ **Simpler testing**: Single file easier to validate and test than directory of files

### Negative

❌ **ConfigMap size**: Consolidating resources into single multi-document YAML files may significantly increase ConfigMap size (1 MiB limit)

## Notes

**Related ADRs:**
- ADR-001 (Flavour-Based Configuration): Provides flavour infrastructure this integrates with
- ADR-002 (DevHubPluginCatalog CRD): Catalog system that defines plugins
- ADR-003 (Operator-Based Plugin Configuration Processing): Plugin config processing that references dependencies

**Future considerations:**
- Catalog-based dependency definition: Move dependency specifications from operator code to catalog entries, same way as for other part of plugin
