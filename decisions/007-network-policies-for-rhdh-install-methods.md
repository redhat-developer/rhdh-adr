# ADR: Tailored NetworkPolicies for RHDH Install Methods

## Context

**Problem**: RHDH deployments currently lack NetworkPolicies, leaving both inbound and outbound traffic unrestricted. This exposes deployments to two categories of risk: unauthorized access to RHDH pods from other workloads (lateral movement), and unrestricted outbound traffic from RHDH pods to external or internal destinations (data exfiltration, communication with unauthorized endpoints).

The absence of NetworkPolicies was identified as a risk in the OCP Threat Model ([OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819)). Additionally, shipping NetworkPolicies for operator-managed workloads is now a requirement for all Red Hat Operators targeting OCP 5+. Today, the only NetworkPolicies shipped by RHDH are specific to the Orchestrator flavor; the base RHDH deployment (both Operator-managed operands and Helm chart) has no network traffic restrictions at all. This means:

- **Ingress**: Any pod in the namespace (or cluster, depending on the network plugin) can reach RHDH pods and its dependencies (PostgreSQL, etc.) without restriction
- **Egress**: RHDH pods can make unrestricted outbound connections to any destination, increasing the blast radius if a pod is compromised
- There is no defense-in-depth at the network layer for the most common deployment scenarios

Additionally, RHDH is supported across multiple Kubernetes platforms (OCP, EKS, AKS, GKE), each with different levels of default NetworkPolicy enforcement. OCP enforces NetworkPolicies out of the box, but other platforms may require users to configure a compatible CNI plugin.

Unlike typical workloads with known, predictable network flows, RHDH is a platform whose egress patterns are largely defined by its plugins. Even officially supported plugins can be configured with customer-specific endpoints (e.g., a self-hosted GitLab instance, an internal artifact registry, a corporate OIDC provider), making egress destinations unpredictable. This fundamentally limits how restrictive the base egress policies can be.

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

- **Default deny with selective allow**: Apply a default-deny policy scoped to RHDH-labeled pods (not namespace-wide, since RHDH is a layered product that may share namespaces), then add specific allow rules for known traffic flows. This applies to all RHDH-managed pods, not just the RHDH backend. Each component (e.g., RHDH backend, PostgreSQL) gets its own policies appropriate to its role, ensuring defense-in-depth across all components
- **Ingress policies**: Allow inbound traffic only from expected sources:
  - OpenShift Router / Ingress controller to the RHDH backend (for user access via Routes/Ingresses)
  - Monitoring/metrics scrapers to the metrics endpoints
  - Inter-pod communication between RHDH components (e.g., backend to PostgreSQL)
- **Egress policies**: Egress rules vary by component. Components that do not need external access (e.g., PostgreSQL) are locked down to minimal egress (DNS only, plus in-namespace traffic from/to RHDH). The RHDH backend pod, however, needs to reach a wide range of external destinations (plugin registries, LLM endpoints, SCM providers, auth providers, etc.) whose IP addresses are not predictable. Since NetworkPolicies can only filter by CIDR, not by DNS name, the base egress policy for the RHDH backend pod will in practice need to allow outbound HTTPS (port 443) broadly. This is an acknowledged trade-off: the RHDH backend egress is closer to "deny everything except DNS + HTTPS" than a strict per-destination allowlist. The defense-in-depth value comes from per-component granularity (PostgreSQL stays locked down) and from blocking non-standard ports, rather than from restricting which HTTPS destinations the backend can reach. The base egress rules include:
  - DNS resolution (cluster DNS service) for all RHDH-managed pods
  - Kubernetes API server access for the RHDH backend (for service discovery, CR watches, etc.)
  - PostgreSQL, either in-namespace (podSelector-based) or external (user-configurable CIDR/port rule when the database lives outside the cluster)
  - HTTPS egress (port 443) for the RHDH backend, covering plugin registries (e.g., registry.access.redhat.com, quay.io, npm.registry.redhat.com), Lightspeed model endpoints, and other external services
  - Cross-namespace traffic to OpenShift Serverless and Serverless Logic namespaces when the Orchestrator flavor is enabled
  - Any additional egress not covered by the above (e.g., non-standard ports, corporate proxy endpoints configured via HTTP_PROXY/HTTPS_PROXY) is left to the user to allow via their own additive NetworkPolicy resources
- **Clear boundary between base and user-managed policies**: The base policies shipped by the Operator and Helm chart cover DNS, API server access, PostgreSQL, broad HTTPS egress for the RHDH backend, and Orchestrator cross-namespace traffic. Egress on non-standard ports or to destinations not reachable over HTTPS (e.g., corporate proxies on custom ports) is the user's responsibility to allow via additive policies.
- **User-extensible via additive policies**: This split is possible because Kubernetes NetworkPolicies are **additive**: once a default-deny policy selects a pod, any additional NetworkPolicy matching that pod can only add more allow rules, never remove existing ones. Users who need to allow additional site-specific traffic simply create their own NetworkPolicy resources in the same namespace. These compose naturally with the base policies without any CRD or Helm values change. The base NetworkPolicies are always present and cannot be disabled. On clusters without NetworkPolicy enforcement, they simply have no effect
- **Documentation**: Clear documentation is essential to make this approach work in practice. Users need to understand which base policies are shipped, what traffic they allow and deny, how to create additional NetworkPolicies for their site-specific needs, and how to troubleshoot connectivity issues caused by policies. Documentation should also clarify the requirement for a NetworkPolicy-capable CNI plugin on non-OCP platforms, and provide ready-to-use NetworkPolicy templates for common plugin egress scenarios (e.g., GitHub/GitLab SCM access, Quay/Artifactory registries, OIDC providers) that users can copy and adapt for their environment
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

### Alternative 4: Ingress-only policies by default, egress as opt-in
- **Approach**: Ship only ingress policies (restricting which pods can reach RHDH) and leave egress unrestricted by default. Egress lockdown would be an opt-in hardening step for security-focused teams.
- **Rejected because**: Ingress-only policies address lateral movement but leave the outbound attack surface completely open. A compromised RHDH pod could still exfiltrate data or communicate with unauthorized destinations. [OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819) requires the default supported setup to be secure out of the box, covering both ingress and egress. The base egress policies are designed to cover all known traffic flows for officially supported plugins (GA and TP), so the default deployment works without manual intervention. Only users with custom or community plugins that target endpoints not covered by the base policies would need to add their own rules.

### Alternative 5: Use AdminNetworkPolicy (ANP) / BaselineAdminNetworkPolicy (BANP) instead of standard NetworkPolicies
- **Approach**: Use the AdminNetworkPolicy (ANP) or BaselineAdminNetworkPolicy (BANP) resources, as recommended for consideration by the parent outcome [HPSTRAT-104](https://redhat.atlassian.net/browse/HPSTRAT-104).
- **Rejected because**: ANP and BANP are cluster-scoped resources that require cluster-admin privileges to create and manage. For the Helm chart path, releases can be deployed by regular cluster users who do not have cluster-admin privileges, so they simply cannot create ANP/BANP resources. For the Operator path, the Operator is installed by a cluster admin, so it could in theory deploy ANP/BANP. However, this would need to happen at Operator install time by shipping the policies in the Operator bundle (OLM), which is blocked until OLM NetworkPolicy support is backported ([RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351)). ANP/BANP are designed for platform-level network governance enforced by cluster admins, not for individual workload self-protection by operators. They also require specific CNI support and are not universally available across all RHDH-supported platforms (EKS, AKS, GKE). Standard namespace-scoped NetworkPolicies are the appropriate tool for a layered product. Note that cluster admins can still layer ANP/BANP on top of RHDH's standard NetworkPolicies for additional cluster-wide enforcement, but that is outside RHDH's scope.

### Alternative 6: Rely solely on documentation and leave NetworkPolicies to the user
- **Approach**: Document recommended NetworkPolicies without shipping them
- **Rejected because**: This puts the burden on every deployer to understand RHDH traffic patterns and write correct policies. Most users would not implement them, leaving deployments unprotected. Shipping sensible defaults with the ability to customize is a better security posture.

## Consequences

### Positive
- ✅ Enforces least-privilege network access by default, reducing the attack surface for RHDH deployments
- ✅ Addresses the risk identified in the OCP Threat Model ([OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819))
- ✅ Works transparently on OCP, which enforces NetworkPolicies out of the box. No user action required
- ✅ Does not break deployments on clusters without NetworkPolicy enforcement (policies are created but simply not enforced by Kubernetes)
- ✅ Configurable. Users can extend, customize, or disable policies to fit their environment (airgapped, proxied, etc.)
- ✅ Meets the OCP 5+ requirement for shipping NetworkPolicies with operator-managed workloads
- ✅ No CRD or API changes needed. Leverages the additive nature of Kubernetes NetworkPolicies, so extensibility comes for free
- ✅ Per-component policy granularity provides defense-in-depth (e.g., PostgreSQL locked down to minimal egress while the RHDH backend gets broader HTTPS access)

### Negative
- ❌ Users must create their own additional NetworkPolicies for site-specific egress (SCMs, CI/CD, registries, auth providers, etc.). The base policies do not cover these, which requires awareness and documentation
- ❌ Users on non-OCP platforms must ensure their CNI plugin supports NetworkPolicy enforcement. Otherwise, policies exist but provide no actual protection, which requires clear documentation to avoid a false sense of security
- ❌ Adds complexity to the Operator and Helm chart codebases. Policies must be kept in sync with any changes to RHDH pod labels, ports, or component architecture, and must account for optional features (Lightspeed sidecars, Orchestrator cross-namespace flows, external databases)
- ❌ Requires testing across all supported platforms (OCP, EKS, AKS, GKE) and across deployment variants (with/without Lightspeed, Orchestrator, external database) to validate that policies do not inadvertently block legitimate traffic
- ❌ On clusters that enforce NetworkPolicies (e.g., OCP), upgrading to a version that ships these base policies will introduce a default-deny for RHDH pods. Existing deployments that rely on egress to endpoints not covered by the base policies (SCMs, auth providers, registries, etc.) will experience connectivity failures unless users create their own additive NetworkPolicies before or during the upgrade. This upgrade impact must be clearly communicated in release notes and migration guides, including ready-to-use NetworkPolicy templates for common egress scenarios and steps to verify connectivity after the upgrade

### Neutral
- ⚖️ On clusters where administrators purposely do not enforce NetworkPolicies (e.g., no NetworkPolicy-capable CNI plugin configured), these policies will have no effect at all. The policies are created but not enforced, so existing behavior is completely unchanged
- ⚖️ The existing Orchestrator NetworkPolicies (in both `rhdh-operator` and `rhdh-chart`) currently use `podSelector: {}` (namespace-wide), which contradicts the label-scoped principle adopted in this ADR. These policies will need to be rewritten to use RHDH-specific label selectors. This is a breaking change for existing Orchestrator deployments that rely on the current namespace-wide policies
- ⚖️ OLM-managed NetworkPolicies for the operator pod itself remain out of scope until OLM support is backported ([RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351))
- ⚖️ The RHDH must-gather should be updated to collect NetworkPolicies in place, so as to help troubleshoot potential connectivity failures caused by overly restrictive or misconfigured policies

## References

- [Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [OpenShift NetworkPolicy documentation](https://docs.openshift.com/container-platform/4.18/networking/network_security/network_policy/about-network-policy.html)
- [Best Practices for developing Network Policies](https://docs.google.com/document/d/1CDoGSRd-h8VT4PMrK_83Ro0YzYPjORbkxtfTJU1sN6Q/edit?tab=t.0)
- [OCPSTRAT-819: Protect from unintended data leaks / attacks via tailored Network Policies](https://redhat.atlassian.net/browse/OCPSTRAT-819)
- [RHDHPLAN-1032: Add tailored NetworkPolicies to the Install Methods](https://redhat.atlassian.net/browse/RHDHPLAN-1032)
- [RHDHPLAN-351: NetworkPolicies for the RHDH Operator itself (OLM-managed)](https://redhat.atlassian.net/browse/RHDHPLAN-351)
