# ADR: Tailored NetworkPolicies for RHDH Install Methods

## Context

**Problem**: RHDH deployments currently lack NetworkPolicies, leaving pod-to-pod communication unrestricted and exposing the deployment to unintended data leaks or lateral movement attacks.

The absence of NetworkPolicies in RHDH was identified as a risk in the OCP Threat Model ([OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819)). Today, the only NetworkPolicies shipped by RHDH are specific to the Orchestrator flavor; the base RHDH deployment (both Operator-managed operands and Helm chart) has no network traffic restrictions at all. This means:

- Any pod in the namespace (or cluster, depending on the network plugin) can reach RHDH pods and its dependencies (PostgreSQL, etc.) without restriction
- RHDH pods can make unrestricted egress connections, increasing the blast radius if compromised
- There is no defense-in-depth at the network layer for the most common deployment scenarios

Additionally, RHDH is supported across multiple Kubernetes platforms (OCP, EKS, AKS, GKE), each with different levels of default NetworkPolicy enforcement. OCP enforces NetworkPolicies out of the box, but other platforms may require users to configure a compatible CNI plugin.

### Disconnected/airgapped environments

In these environments, RHDH cannot reach public endpoints and instead relies on internal infrastructure. The egress traffic flows affected include:

- **OCI plugin installation**: RHDH may need to dynamically fetch plugins from container registries or NPM registries. In disconnected environments, this traffic targets an internal mirror registry rather than the public registry, and policies must allow egress to that mirror
- **Source control access**: Plugins like the Catalog backend fetch repository content (e.g., `catalog-info.yaml` files) from SCM providers. In disconnected environments, this is a local GitLab/Gitea/etc. instance rather than a public provider like GitHub.
- **Authentication providers**: OIDC/OAuth flows require egress to the identity provider. In disconnected environments, this is typically an internal Keycloak or RHSSO instance
- **Proxy endpoints**: The RHDH proxy may need to forward requests to arbitrary backend services configured by the user, many of which may be internal-only in disconnected setups
- **Custom scaffolder actions**: Software Templates may call internal CI/CD systems, artifact registries, or other internal APIs

Note that container image pulls (for the RHDH pod images themselves) happen at the container runtime level and are **not** affected by NetworkPolicies, which are only about pod-to-pod networking.

Since the specific internal endpoints vary per deployment, default egress policies cannot enumerate them. The policies must therefore either be broadly permissive on common ports (443, 8443, etc.) or provide a clear configuration surface for users to add their site-specific endpoints.

### Advanced deployment scenarios

These introduce additional traffic flows that policies must account for:

- **Lightspeed (enabled by default since RHDH 1.10)**: Lightspeed adds a sidecar container to the RHDH pod that might need egress to LLM inference endpoints. Since NetworkPolicies apply at the pod level (not per container), the base egress policies on the RHDH pod govern the sidecar's traffic as well. Since Lightspeed is enabled by default, the base egress policies must accommodate this traffic.
- **Orchestrator (opt-in)**: The Orchestrator flavor introduces cross-namespace traffic flows with OpenShift Serverless and Serverless Logic operators, and its SonataFlow components (Data Index, Job Service) connect back to RHDH's PostgreSQL. Users may also bring their own external SonataFlowPlatform, requiring egress to endpoints in a different namespace or outside the cluster.
- **External database**: RHDH supports connecting to an external PostgreSQL instance that may live outside of the cluster. Egress policies scoped to in-namespace pods would block this connection.

### Key constraints
- NetworkPolicies must not break existing RHDH functionality on any supported platform
- Deployment must not fail on clusters without NetworkPolicy-capable CNI plugins. But Kubernetes already handles this gracefully as policies will be created but not enforced
- The RHDH Operator itself is installed via OLM, and OLM NetworkPolicy support is still being backported (tracked separately in [RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351)). This ADR covers only the operands managed by the operator and the Helm chart resources
- Policies must be flexible enough for disconnected environments. Users must be able to allowlist their internal endpoints without modifying the default policies directly

## Decision

Add tailored NetworkPolicies to all RHDH install methods (both the operands managed by the RHDH Operator and the resources deployed by the Helm chart) to enforce least-privilege pod communication by default.

**Key design principles**:

- **Default deny with selective allow**: Apply a default-deny policy scoped to RHDH-labeled pods (not namespace-wide, since RHDH is a layered product that may share namespaces), then add specific allow rules for known traffic flows
- **Ingress policies**: Allow inbound traffic only from expected sources:
  - OpenShift Router / Ingress controller to the RHDH backend (for user access via Routes/Ingresses)
  - Monitoring/metrics scrapers to the metrics endpoints
  - Inter-pod communication between RHDH components (e.g., backend to PostgreSQL)
- **Egress policies**: Allow outbound traffic for:
  - DNS resolution (cluster DNS service)
  - Kubernetes API server access (for service discovery, CR watches, etc.)
  - PostgreSQL, either in-namespace (podSelector-based) or external (user-configurable CIDR/port rule when the database lives outside the cluster)
  - AI model endpoints for Lightspeed, either cluster-internal model servers or external LLM APIs
  - Cross-namespace traffic to OpenShift Serverless and Serverless Logic namespaces when the Orchestrator flavor is enabled
  - Any additional egress (SCM providers, CI/CD systems, container registries, etc.) is left to the user to allow via their own additive NetworkPolicy resources, since these destinations are deployment-specific
- **Clear boundary between base and user-managed policies**: The base policies shipped by the Operator and Helm chart cover only the core traffic flows that are common to all RHDH deployments (DNS, API server, PostgreSQL, Lightspeed model endpoints, Orchestrator cross-namespace traffic). All deployment-specific egress (SCM providers, CI/CD systems, container registries, auth providers, internal mirrors, external SonataFlowPlatform endpoints, etc.) is the user's responsibility to allow.
- **User-extensible via additive policies**: This split is possible because Kubernetes NetworkPolicies are **additive**: once a default-deny policy selects a pod, any additional NetworkPolicy matching that pod can only add more allow rules, never remove existing ones. Users who need to allow additional site-specific traffic simply create their own NetworkPolicy resources in the same namespace. These compose naturally with the base policies without any CRD or Helm values change. The only configuration surface needed in the Operator CR and Helm values is a boolean to disable the base NetworkPolicies entirely (for clusters without enforcement or for debugging)
- **Documentation**: Clear documentation is essential to make this approach work in practice. Users need to understand which base policies are shipped, what traffic they allow and deny, how to create additional NetworkPolicies for their site-specific needs, and how to troubleshoot connectivity issues caused by policies. Documentation should also clarify the requirement for a NetworkPolicy-capable CNI plugin on non-OCP platforms and provide guidance for common scenarios (disconnected environments, external databases, custom plugins reaching additional endpoints)
- **Label-scoped policies**: Since RHDH is a layered product deployed into potentially shared namespaces, policies use `podSelector` with RHDH-specific labels rather than namespace-wide selectors, following the OCP best practice for layered products
- **Operator vs. OLM boundary**: The RHDH Operator manages NetworkPolicies for its operands (RHDH pods, PostgreSQL, etc.) directly. NetworkPolicies for the operator pod itself are out of scope here and will be handled via OLM once support is fully backported ([RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351))

## Alternatives considered

### Alternative 1: Namespace-wide default deny
- **Approach**: Apply a blanket default-deny policy with `podSelector: {}` covering all pods in the namespace
- **Rejected because**: RHDH is a layered product that may be deployed into shared namespaces (including `openshift-operators`). A namespace-wide deny would break other workloads not managed by RHDH. The OCP NetworkPolicy best practices explicitly recommend label-scoped policies for layered products.

### Alternative 2: Egress restrictions by specific destination CIDRs
- **Approach**: Lock down egress to only known CIDRs for external services (e.g., GitHub IP ranges, specific registry IPs)
- **Rejected because**: RHDH integrates with a wide variety of user-configured external services (SCMs, CI/CD, auth providers, plugin registries, internal mirrors). NetworkPolicies cannot use DNS names, only CIDRs. Maintaining an accurate CIDR list is impractical and would break frequently. Port-based egress rules combined with user-configurable overrides provide a better balance of security and usability.

### Alternative 3: Expose custom NetworkPolicy rules in the Operator CR
- **Approach**: Add fields like `spec.networkPolicies.additionalEgressRules[]` and `spec.networkPolicies.additionalIngressRules[]` to the Backstage CR schema, allowing users to declare custom allow rules through the Operator's configuration surface
- **Rejected because**: The Backstage CR currently has no such fields, and since NetworkPolicies are additive, users can achieve the same result by creating their own NetworkPolicy resources directly in the namespace. No CRD schema change is needed. Adding these fields would increase the API surface and maintenance burden of the Operator for no functional benefit over user-managed policies. Note: the upstream Backstage Helm chart already provides a [`networkPolicy`](https://github.com/redhat-developer/rhdh-chart/blob/release-1.10/charts/backstage/vendor/backstage/charts/backstage/values.yaml#L392-L428) section in `values.yaml` with `ingressRules.customRules[]`, `egressRules.customRules[]`, and a `denyConnectionsToExternal` toggle. This existing Helm mechanism is sufficient for Helm-based deployments and does not need to be replicated in the Operator CR.

### Alternative 4: Rely solely on documentation and leave NetworkPolicies to the user
- **Approach**: Document recommended NetworkPolicies without shipping them
- **Rejected because**: This puts the burden on every deployer to understand RHDH traffic patterns and write correct policies. Most users would not implement them, leaving deployments unprotected. Shipping sensible defaults with the ability to customize is a better security posture.

## Consequences

### Positive
- ✅ Enforces least-privilege network access by default, reducing the attack surface for RHDH deployments
- ✅ Addresses the risk identified in the OCP Threat Model ([OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819))
- ✅ Works transparently on OCP, which enforces NetworkPolicies out of the box. No user action required
- ✅ Does not break deployments on clusters without NetworkPolicy enforcement (policies are created but simply not enforced by Kubernetes)
- ✅ Configurable. Users can extend, customize, or disable policies to fit their environment (airgapped, proxied, etc.)

### Negative
- ❌ Users must create their own additional NetworkPolicies for site-specific egress (SCMs, CI/CD, registries, auth providers, etc.). The base policies do not cover these, which requires awareness and documentation
- ❌ Users on non-OCP platforms must ensure their CNI plugin supports NetworkPolicy enforcement. Otherwise, policies exist but provide no actual protection, which requires clear documentation to avoid a false sense of security
- ❌ Adds complexity to the Operator and Helm chart codebases. Policies must be kept in sync with any changes to RHDH pod labels, ports, or component architecture, and must account for optional features (Lightspeed sidecars, Orchestrator cross-namespace flows, external databases)
- ❌ Requires testing across all supported platforms (OCP, EKS, AKS, GKE) and across deployment variants (with/without Lightspeed, Orchestrator, external database) to validate that policies do not inadvertently block legitimate traffic
- ❌ On clusters that enforce NetworkPolicies (e.g., OCP), upgrading to a version that ships these base policies will introduce a default-deny for RHDH pods. Existing deployments that rely on egress to endpoints not covered by the base policies (SCMs, auth providers, registries, etc.) will experience connectivity failures unless users create their own additive NetworkPolicies before or during the upgrade. This upgrade impact must be clearly communicated in release notes and migration guides

### Neutral
- ⚖️ On clusters where administrators purposely do not enforce NetworkPolicies (e.g., no NetworkPolicy-capable CNI plugin configured), these policies will have no effect at all. The policies are created but not enforced, so existing behavior is completely unchanged
- ⚖️ The Orchestrator-specific NetworkPolicies already in place will need to be reconciled with the new base policies to avoid duplication or conflicts
- ⚖️ OLM-managed NetworkPolicies for the operator pod itself remain out of scope until OLM support is backported ([RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351))
- ⚖️ The RHDH must-gather should be updated to collect NetworkPolicies in place, so as to help troubleshoot potential connectivity failures caused by overly restrictive or misconfigured policies

## References

- [Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [OpenShift NetworkPolicy documentation](https://docs.openshift.com/container-platform/4.18/networking/network_security/network_policy/about-network-policy.html)
- [Best Practices for developing Network Policies](https://docs.google.com/document/d/1CDoGSRd-h8VT4PMrK_83Ro0YzYPjORbkxtfTJU1sN6Q/edit?tab=t.0)
- [OCPSTRAT-819: Protect from unintended data leaks / attacks via tailored Network Policies](https://redhat.atlassian.net/browse/OCPSTRAT-819)
- [RHDHPLAN-1032: Add tailored NetworkPolicies to the Install Methods](https://redhat.atlassian.net/browse/RHDHPLAN-1032)
- [RHDHPLAN-351: NetworkPolicies for the RHDH Operator itself (OLM-managed)](https://redhat.atlassian.net/browse/RHDHPLAN-351)
