# ADR: Reconciliation Pause for Backstage CR

## Context

**Problem**: The RHDH operator has no mechanism to temporarily halt reconciliation of a Backstage CR, forcing SREs to either race the operator when making manual fixes or scale down the operator deployment entirely (affecting all Backstage instances in the cluster).

The RHDH operator uses Server-Side Apply with `Force: true` on every reconciliation cycle. This means any manual change to operator-managed resources (Deployment, StatefulSet, ConfigMaps, Services) is overwritten within seconds. During upgrade failures or incident response, this creates a direct conflict between the operator and the humans trying to fix the problem.

**Evidence from support cases:**

Across 20+ upgrade-related Jira issues (RHDHSUPP-404, RHDHSUPP-364, RHDHSUPP-400, RHDHSUPP-142, and others), the resolution pattern is consistent:

1. Customer upgrades RHDH (via OLM or Helm)
2. New version fails to start (database conflict, plugin incompatibility, missing config, lock file deadlock)
3. Pods enter CrashLoopBackOff
4. Support team identifies the fix (rename a database schema, delete a lock file, revert an image, adjust config)
5. **Applying the fix is blocked by the operator** — every manual change is overwritten by the next reconciliation

Specific examples:
- **RHDHSUPP-404** (pgvector schema conflict): SRE needs to fix the database schema, but the operator keeps deploying the crashing version
- **RHDHSUPP-364** (lock file deadlock): SRE needs to delete a stale lock file from the PVC, but the operator keeps recreating the stuck pod
- **RHDHSUPP-400** (plugin failure after upgrade): Support needs to test with different images to diagnose which version broke plugins, but the operator overwrites image changes immediately
- **RHDHSUPP-142** (PVC multi-attach timeout): SRE needs to manually delete a stuck pod to release a RWO volume, but the operator's reconciliation interferes with the rollout

Today, the only way to stop the operator from interfering is to scale down the operator Deployment (`kubectl scale deployment rhdh-operator --replicas=0`), which affects **all** Backstage CRs in the cluster — not just the one being fixed.

**Who is impacted:**
- **SREs and support engineers**: Cannot make manual fixes during incidents without fighting the operator
- **Cluster administrators**: Must choose between affecting all instances or racing the reconciliation loop
- **Customers**: Extended downtime while support coordinates fixes that the operator undoes

**Constraints:**
- Must not require CRD schema changes (the API is at v1alpha5 and follows a conservative versioning policy per [ADR-005](005-crd-version-management.md))
- Must be consistent with existing operator annotation patterns (`rhdh.redhat.com/idle`)
- Must not block resource deletion (finalizers must still run)
- Must provide clear status indication so users can confirm the pause is active

## Decision

Add an annotation-based reconciliation pause: when `rhdh.redhat.com/pause: "true"` is set on a Backstage CR, the operator skips all reconciliation for that CR and reports the pause via a status condition.

**Implementation approach:**

1. **Annotation check at reconcile entry**: Immediately after loading the Backstage CR in the `Reconcile` function, check for the `rhdh.redhat.com/pause` annotation. If set to `"true"`, update the status condition and return without performing any reconciliation steps (no `preprocessSpec`, no `InitObjects`, no `applyObjects`).

2. **Status condition while paused**: The existing `Deployed` condition is **preserved as-is** — its last-known value reflects the actual workload state and must not be overwritten. A separate `Paused` condition is added to signal that reconciliation is halted:
   ```yaml
   status:
     conditions:
       - type: Deployed
         status: "False"           # preserved from before pause — reflects actual state
         reason: DeployFailed
         message: "failed to apply backstage objects: ..."
       - type: Paused
         status: "True"
         reason: UserRequested
         message: "Reconciliation paused by user"
   ```
   This avoids falsely signaling a healthy deployment when the workload may be unhealthy or never deployed. When reconciliation resumes, the `Paused` condition is removed and the `Deployed` condition is updated by normal reconciliation logic.

3. **Deletion is not blocked**: If the Backstage CR is being deleted (has a `DeletionTimestamp`), the pause annotation is ignored and finalizer logic runs normally. This prevents the Crossplane anti-pattern where paused resources cannot be garbage collected.

4. **Kubernetes Events**: Emit a Kubernetes Event when reconciliation is paused and when it resumes, providing an audit trail.

5. **Unpause triggers immediate reconciliation**: Since the annotation change triggers a watch event on the Backstage CR, removing the annotation causes the operator to reconcile immediately without waiting for the next scheduled sync.

6. **`operator-lib` provides this out of the box**: The Operator Framework's shared library [`operator-lib`](https://github.com/operator-framework/operator-lib/pull/60) implements annotation-based pause as a reusable `Predicate` and `EventHandler` via `NewPause(key)`. This was added after an [Operator SDK maintainer explicitly recommended annotation over spec field](https://github.com/operator-framework/operator-sdk/issues/3418#issuecomment-661149919) for pause semantics. The RHDH operator can either adopt `operator-lib` as a dependency and use `NewPause("rhdh.redhat.com/pause")`, or implement the equivalent logic manually (~10 lines). The team should decide based on whether the additional dependency is justified.

**Implementation in `backstage_controller.go`:**

The reconciler needs an `EventRecorder` (standard controller-runtime pattern, injected via the manager):

```go
type BackstageReconciler struct {
    client.Client
    Scheme   *runtime.Scheme
    Platform platform.Platform
    Recorder record.EventRecorder  // added for pause/resume audit trail
}
```

Pause check with event recording and resume detection:

```go
func (r *BackstageReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    lg := log.FromContext(ctx)

    backstage := api.Backstage{}
    if err := r.Get(ctx, req.NamespacedName, &backstage); err != nil {
        if errors.IsNotFound(err) {
            lg.Info("backstage gone from the namespace")
            return ctrl.Result{}, nil
        }
        return ctrl.Result{}, fmt.Errorf("failed to load backstage deployment from the cluster: %w", err)
    }

    isPaused := backstage.GetAnnotations()["rhdh.redhat.com/pause"] == "true"
    wasPaused := meta.IsStatusConditionTrue(backstage.Status.Conditions, "Paused")

    // Pause check — skip reconciliation if paused (but allow deletion)
    if isPaused && backstage.DeletionTimestamp.IsZero() {
        if !wasPaused {
            // Transition: running → paused — update status and emit event once
            r.Recorder.Event(&backstage, corev1.EventTypeNormal,
                "ReconciliationPaused", "Reconciliation paused by user")
            setStatusCondition(&backstage, "Paused",
                metav1.ConditionTrue, "UserRequested", "Reconciliation paused by user")
            if err := r.Client.Status().Update(ctx, &backstage); err != nil {
                return ctrl.Result{}, err
            }
        }
        // Already paused — return without writing status to avoid a hot loop
        // (status writes bump resourceVersion, triggering another reconciliation)
        return ctrl.Result{}, nil
    }

    // Resume detection: was paused, now unpaused
    if wasPaused && !isPaused {
        r.Recorder.Event(&backstage, corev1.EventTypeNormal,
            "ReconciliationResumed", "Reconciliation resumed by user")
        meta.RemoveStatusCondition(&backstage.Status.Conditions, "Paused")
    }

    // ... existing reconciliation logic continues unchanged
}
```

**User workflow:**

```bash
# Pause reconciliation for a specific instance
kubectl annotate backstage my-rhdh rhdh.redhat.com/pause=true

# Verify pause is active (check the Paused condition)
kubectl get backstage my-rhdh -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}'
# Output: True

# Make manual fixes (database, config, image, PVC, etc.)
kubectl set image deployment/backstage-my-rhdh backstage-backend=quay.io/rhdh/rhdh:1.8.5

# Fix the root cause in the CR spec or config BEFORE resuming
kubectl edit backstage my-rhdh  # e.g., fix database config, plugin settings, etc.

# Resume reconciliation
kubectl annotate backstage my-rhdh rhdh.redhat.com/pause-
```

**Resume behavior:** When the pause annotation is removed, the operator runs a full reconciliation with Server-Side Apply (`Force: true`). This **overwrites all manual changes** made while paused — the operator restores its desired state from the CR spec and default templates. Manual fixes to Deployments, ConfigMaps, or other operator-managed resources do not survive the resume.

This means pause is for **diagnosis and temporary stabilization**, not permanent manual overrides. The correct workflow is:

1. **Pause** — stop the operator from interfering
2. **Diagnose** — make manual changes to identify the problem (test different images, check database, etc.)
3. **Fix the source of truth** — update the CR spec, ConfigMap, or operator config to address the root cause
4. **Resume** — operator reconciles with the corrected configuration

**Pause vs. idle:** The existing `rhdh.redhat.com/idle` annotation is not a substitute for pause. Idle runs the full reconcile loop and applies all resources via SSA — it just sets replicas to 0. The operator is still actively managing the instance, so manual changes to operator-managed resources are still overwritten. Pause skips the entire reconcile loop, leaving all cluster resources untouched.

## Alternatives Considered

### Alternative 1: `spec.paused` API field
- **Approach**: Add a `paused: bool` field to the Backstage CR spec, following the Cluster API (CAPI) and Flux patterns
- **Rejected because**: Requires a CRD schema change. Under the conservative versioning policy ([ADR-005](005-crd-version-management.md)), adding a new field to the current v1alpha5 version is possible (it's a compatible addition), but an annotation-based approach is simpler to implement, requires no CRD regeneration, and is consistent with the existing `rhdh.redhat.com/idle` annotation pattern already used by the operator. Can be reconsidered if the API graduates to v1beta1.

### Alternative 2: Global operator-level pause (flag or ConfigMap)
- **Approach**: A flag or ConfigMap that pauses reconciliation for all Backstage CRs managed by the operator
- **Rejected because**: Too coarse-grained. In multi-tenant clusters with multiple Backstage instances, pausing all instances to fix one is the same problem as scaling down the operator. The annotation approach provides per-CR granularity.

### Alternative 3: Auto-expiring pause (`pauseUntil` with RFC3339 timestamp)
- **Approach**: Following HyperShift's pattern, accept an RFC3339 timestamp as the annotation value to auto-expire the pause
- **Rejected because**: Adds complexity for a v1 implementation. A forgotten pause is a real risk, but it can be mitigated by documentation and monitoring. Auto-expiry can be added later as an enhancement without changing the annotation key (the value format is already flexible: `"true"` for indefinite, RFC3339 for auto-expiry).

## Consequences

### Positive
- ✅ **Immediate incident response**: SREs can freeze a specific Backstage instance and make manual fixes without the operator undoing their work
- ✅ **Per-instance granularity**: Only the affected instance is paused; other instances in the cluster continue normal reconciliation
- ✅ **Minimal implementation surface**: ~10 lines of Go code in the reconcile loop — low risk of regressions
- ✅ **No CRD changes required**: Annotation-based approach requires no schema changes or CRD regeneration
- ✅ **Consistent with existing patterns**: Follows the same `rhdh.redhat.com/*` annotation convention as the existing idle annotation
- ✅ **Strong industry precedent**: CAPI, Flux, Strimzi, Crunchy PGO, Crossplane, ECK, Argo CD, Confluent, and Prometheus Operator all support reconciliation pause
- ✅ **Supports phased upgrades**: In multi-instance clusters, pause all CRs before an operator upgrade, then unpause one at a time for controlled rollout (Strimzi's documented pattern)

### Negative
- ❌ **Drift accumulation**: While paused, the CR's desired state and actual cluster state can diverge. Extended pauses may cause a large reconciliation on resume
- ❌ **No auto-expiry**: A forgotten pause annotation leaves the instance unmanaged indefinitely (mitigated by documentation and potential future enhancement)
- ❌ **Not discoverable via CRD schema**: Unlike `spec.paused`, an annotation doesn't appear in `kubectl explain` output. Users must know the annotation key

### Neutral
- ⚖️ Pause is a response tool, not a prevention tool — it does not detect or prevent upgrade failures, only enables human intervention after they occur
- ⚖️ Can be upgraded to `spec.paused` in a future API version if the team decides the discoverability trade-off justifies a schema change
- ⚖️ The operator already has precedent for annotation-driven behavior (`rhdh.redhat.com/idle`), so this is a natural extension of the existing pattern

## References

- [Cluster API pause documentation](https://main.cluster-api.sigs.k8s.io/developer/providers/contracts/infra-cluster) — `spec.paused` + annotation dual mechanism
- [Flux suspend documentation](https://fluxcd.io/flux/components/helm/helmreleases/) — `spec.suspend` on all Flux objects
- [Strimzi pause reconciliation](https://strimzi.io/blog/2025/04/10/phased-strimzi-upgrade-example/) — annotation-based, phased upgrade pattern
- [HyperShift pausedUntil](https://hypershift-docs.netlify.app/how-to/pause-reconciliation/) — auto-expiring pause
- [Crossplane pause issue #4839](https://github.com/crossplane/crossplane/issues/4839) — anti-pattern: deletion blocked by pause
- [Operator SDK discussion #3418](https://github.com/operator-framework/operator-sdk/issues/3418) — framework-level pause discussion (maintainer recommended annotation over spec field)
- [operator-lib PR #60](https://github.com/operator-framework/operator-lib/pull/60) — official `NewPause(key)` implementation in operator-framework's shared library
- [RHDHSUPP-404](https://redhat.atlassian.net/browse/RHDHSUPP-404) — pgvector schema conflict (triggering issue)
- [RHDHSUPP-364](https://redhat.atlassian.net/browse/RHDHSUPP-364) — lock file deadlock
- [RHDHSUPP-400](https://redhat.atlassian.net/browse/RHDHSUPP-400) — plugin failure after upgrade
- [ADR-005: CRD Version Management](005-crd-version-management.md) — conservative versioning policy
