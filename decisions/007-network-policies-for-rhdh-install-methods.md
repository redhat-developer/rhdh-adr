# ADR: Tailored NetworkPolicies for RHDH Application Workloads

## Context

**Problem**: RHDH deployments currently lack NetworkPolicies, leaving both inbound and outbound traffic unrestricted. This exposes deployments to two categories of risk: unauthorized access to RHDH pods from other workloads (lateral movement), and unrestricted outbound traffic from RHDH pods to external or internal destinations (data exfiltration, communication with unauthorized endpoints).

The absence of NetworkPolicies was identified as a risk in the OCP Threat Model ([OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819)). Additionally, shipping NetworkPolicies for operator-managed workloads is now a requirement for all Red Hat Operators targeting OCP 5+. Today, the only NetworkPolicies shipped by RHDH are specific to the Orchestrator flavor; the base RHDH deployment (both Operator-managed operands and Helm chart) has no network traffic restrictions at all. This means:

- **Ingress**: Any pod in the namespace (or cluster, depending on the network plugin) can reach RHDH pods and its dependencies (PostgreSQL, etc.) without restriction
- **Egress**: RHDH pods can make unrestricted outbound connections to any destination, increasing the blast radius if a pod is compromised
- There is no defense-in-depth at the network layer for the most common deployment scenarios

### Key constraints
- NetworkPolicies must not break existing RHDH functionality on any supported platform
- Unlike typical workloads with known, predictable network flows, RHDH is a platform whose egress patterns are largely defined by its plugins. Even officially supported plugins can be configured with customer-specific endpoints (e.g., a self-hosted GitLab instance, an internal artifact registry, a corporate OIDC provider), making egress destinations unpredictable. This fundamentally limits how restrictive the base egress policies can be
- RHDH is supported across multiple Kubernetes platforms (OCP, EKS, AKS, GKE), each with different levels of default NetworkPolicy enforcement. OCP enforces NetworkPolicies out of the box, but other platforms may require users to configure a compatible CNI plugin
- Some features and deployment scenarios introduce additional traffic patterns that policies must account for: Lightspeed sidecars (enabled by default since RHDH 1.10), Orchestrator cross-namespace flows, and external databases; each potentially requiring rules for cross-namespace communication or egress on non-standard ports
- Disconnected/airgapped environments do not change the policy structure; the same traffic flows apply, but destinations point to internal mirrors with different CIDRs. Policies must allow users to allowlist their site-specific endpoints without modifying the defaults directly
- The RHDH Operator itself is installed via OLM, and OLM NetworkPolicy support is still being backported (tracked separately in [RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351)). This ADR covers only the operands managed by the operator and the Helm chart resources
- Deployment must not fail on clusters without NetworkPolicy-capable CNI plugins. But Kubernetes already handles this gracefully as policies will be created but not enforced

## Decision

Add tailored NetworkPolicies to all RHDH application workloads (both the operands managed by the RHDH Operator and the resources deployed by the Helm chart) to enforce least-privilege pod communication by default.

**Key design principles**:

- **Default deny with selective allow**: Apply a default-deny policy scoped to RHDH-labeled pods (not namespace-wide, since RHDH is a layered product that may share namespaces), then add specific allow rules for known traffic flows. This applies to all RHDH-managed pods, not just the RHDH backend. Each component (e.g., RHDH backend, PostgreSQL) gets its own policies appropriate to its role, ensuring defense-in-depth across all components
- **Ingress policies**: Allow inbound traffic only from expected sources:
  - OpenShift Router / Ingress controller to the RHDH backend (for user access via Routes/Ingresses)
  - Monitoring/metrics scrapers to the metrics endpoints (e.g., Prometheus scraping the OpenTelemetry metrics port 9464, restricted to the monitoring namespace)
  - Inter-pod communication between RHDH components (e.g., backend to PostgreSQL)
- **Egress policies**: Egress rules vary by component. Components that do not need external access (e.g., PostgreSQL) are locked down to minimal egress (DNS only, plus in-namespace traffic from/to RHDH). The RHDH backend pod, however, needs to reach a wide range of external destinations (plugin registries, LLM endpoints, SCM providers, auth providers, etc.) whose IP addresses are not predictable. Since NetworkPolicies can only filter by CIDR, not by DNS name, the base egress policy for the RHDH backend pod will in practice need to allow outbound HTTPS (port 443) broadly. This is an acknowledged trade-off: the RHDH backend egress is closer to "deny everything except DNS + HTTPS" than a strict per-destination allowlist. The defense-in-depth value comes from per-component granularity (PostgreSQL stays locked down) and from blocking non-standard ports, rather than from restricting which HTTPS destinations the backend can reach. The base egress rules include:
  - DNS resolution (cluster DNS service) for all RHDH-managed pods
  - Kubernetes API server access for the RHDH backend (for service discovery, CR watches, etc.)
  - PostgreSQL, either in-namespace (podSelector-based) or external (user-configurable CIDR/port rule when the database lives outside the cluster)
  - HTTPS egress (port 443) for the RHDH backend, covering most external service communication (plugin registries, SCM providers, auth providers, etc.)
  - Any additional egress not covered by the above (e.g., non-standard ports, corporate proxy endpoints configured via HTTP_PROXY/HTTPS_PROXY) is left to flavour-conditional or user-managed additive NetworkPolicy resources (see three categories below)
- **Three categories of policies**:
  - **Always-on base policies**: shipped by the Operator and Helm chart, always present. These cover DNS, API server access, PostgreSQL, broad HTTPS egress for the RHDH backend, and monitoring/metrics scraping
  - **Flavour-conditional policies (auto-managed)**: tied to specific flavours or features. For the Operator, these live in the flavour manifests and are reconciled when the flavour is enabled in the CR. For the Helm chart, they are activated by values (e.g., `orchestrator.enabled=true`, `global.lightspeed.enabled=true`). These are shipped and auto-managed, not user-managed. An example is Orchestrator cross-namespace traffic to OpenShift Serverless and Serverless Logic namespaces
  - **User-managed additive policies**: site-specific policies for endpoints that vary per deployment (external database CIDRs, corporate proxies on custom ports, customer-specific SCM/auth providers, plugin endpoints on non-standard ports, etc.). Users create these as additive NetworkPolicy resources in the same namespace
- **User-extensible via additive policies**: Since Kubernetes NetworkPolicies are additive (they can only add allow rules, never remove existing ones), users can extend the base policies by creating their own NetworkPolicy resources in the same namespace without any CRD or Helm values change
- **Documentation**: Clear documentation is essential to make this approach work in practice. Users need to understand which base policies are shipped, what traffic they allow and deny, how to create additional NetworkPolicies for their site-specific needs, and how to troubleshoot connectivity issues caused by policies. Documentation should also clarify the requirement for a NetworkPolicy-capable CNI plugin on non-OCP platforms, and provide ready-to-use NetworkPolicy templates for common plugin egress scenarios (e.g., GitHub/GitLab SCM access, Quay/Artifactory registries, OIDC providers) that users can copy and adapt for their environment
- **Label-scoped policies**: Since RHDH is a layered product deployed into potentially shared namespaces, policies use `podSelector` with RHDH-specific labels rather than namespace-wide selectors, following the OCP best practice for layered products. Each NetworkPolicy is scoped to a specific component of a specific instance:
  - **Operator**: CR-specific policies select pods using `rhdh.redhat.com/app: backstage-rhdh-<cr-name>` (RHDH backend) or `rhdh.redhat.com/app: backstage-psql-<cr-name>` (PostgreSQL)
  - **Helm chart**: release-specific policies select pods using the combination of `app.kubernetes.io/instance: <release-name>` and `app.kubernetes.io/component: backstage` (RHDH backend) or `app.kubernetes.io/component: primary` (PostgreSQL)

  **Examples**:

  > The following examples are illustrative. Both the Operator and the Helm chart will ship equivalent policies OOTB when a new RHDH instance is created. The examples alternate between Operator and Helm labels to show how both paths work.

  Default-deny for the RHDH backend (Helm):
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: my-rhdh-helm-default-deny
  spec:
    podSelector:
      matchLabels:
        app.kubernetes.io/instance: my-rhdh-helm
        app.kubernetes.io/component: backstage
    policyTypes:
      - Ingress
      - Egress
  ```

  Allow ingress from the OpenShift Router to the RHDH backend (Operator, OCP-specific):
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: my-rhdh-op-allow-router-ingress
  spec:
    podSelector:
      matchLabels:
        rhdh.redhat.com/app: backstage-rhdh-my-rhdh-op
    policyTypes:
      - Ingress
    ingress:
      - from:
          # OCP-specific: matches the namespace where the OpenShift Router runs.
          # May also allow all hostNetwork traffic.
          - namespaceSelector:
              matchLabels:
                policy-group.network.openshift.io/ingress: ""
        ports:
          - port: 7007
            protocol: TCP
  ```
  > **Note**: This example uses the OCP-specific label `network.openshift.io/policy-group: ingress` to identify the ingress controller namespace. On non-OCP platforms (EKS, AKS, GKE), the `namespaceSelector` must be adapted to match the namespace where the platform's ingress controller runs, or use `namespaceSelector: {}` to allow ingress on port 7007 from any namespace.

  Restrict PostgreSQL egress to DNS only (Operator):
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: my-rhdh-op-psql-allow-dns
  spec:
    podSelector:
      matchLabels:
        rhdh.redhat.com/app: backstage-psql-my-rhdh-op
    policyTypes:
      - Egress
    egress:
      - ports:
          # Standard Kubernetes DNS
          - port: 53
            protocol: UDP
          - port: 53
            protocol: TCP
          # OCP DNS
          - port: 5353
            protocol: UDP
          - port: 5353
            protocol: TCP
  ```

  Allow Prometheus metrics scraping on port 9464 from the monitoring namespace only (Helm):
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: my-rhdh-helm-allow-metrics-ingress
  spec:
    podSelector:
      matchLabels:
        app.kubernetes.io/instance: my-rhdh-helm
        app.kubernetes.io/component: backstage
    policyTypes:
      - Ingress
    ingress:
      - from:
          - namespaceSelector:
              matchLabels:
                # Adapt to match your monitoring namespace
                kubernetes.io/metadata.name: openshift-monitoring
        ports:
          - port: 9464
            protocol: TCP
  ```

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
- **Rejected because**: The Backstage CR currently has no such fields, and since NetworkPolicies are additive, users can achieve the same result by creating their own NetworkPolicy resources directly in the namespace. No CRD schema change is needed. Adding these fields would increase the API surface and maintenance burden of the Operator for no functional benefit over user-managed policies.

### Alternative 4: Ingress-only policies by default, egress as opt-in
- **Approach**: Ship only ingress policies (restricting which pods can reach RHDH) and leave egress unrestricted by default. Egress lockdown would be an opt-in hardening step for security-focused teams.
- **Rejected because**: Ingress-only policies address lateral movement but leave the outbound attack surface completely open. A compromised RHDH pod could still exfiltrate data or communicate with unauthorized destinations. [OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819) requires the default supported setup to be secure out of the box, covering both ingress and egress. The base egress policies cover the most common traffic flows (HTTPS on port 443). Any plugin configured with endpoints on non-standard ports or protocols would need flavour-conditional or user-managed additive policies.

### Alternative 5: Use AdminNetworkPolicy (ANP) / BaselineAdminNetworkPolicy (BANP), or ClusterNetworkPolicy (CNP) later, instead of standard NetworkPolicies
- **Approach**: Use the AdminNetworkPolicy (ANP) or BaselineAdminNetworkPolicy (BANP) resources, or their planned successor ClusterNetworkPolicy (CNP), as seems to be implied by the parent outcome [HPSTRAT-104](https://redhat.atlassian.net/browse/HPSTRAT-104).
- **Rejected because**: Although ANP and BANP are GA since OCP 4.16 ([OCPSTRAT-939](https://redhat.atlassian.net/browse/OCPSTRAT-939)) and will be available in OCP 5, they are cluster-scoped resources that require cluster-admin privileges to create and manage. The OCP team has [confirmed](https://redhat-internal.slack.com/archives/C06UYJ1K941/p1782138704901079) that operators are expected to ship standard NetworkPolicies, not ANP. Operators typically do not have the permissions to create ANP resources, nor are they expected to. ANP/BANP are designed for platform-level network governance enforced by cluster admins (e.g., to override or tighten policies set by individual operators), not for individual workload self-protection. For the Helm chart path, releases can be deployed by regular cluster users who do not have cluster-admin privileges, so they simply cannot create ANP/BANP resources. They are also not GA in upstream Kubernetes and not universally available across all RHDH-supported platforms (EKS, AKS, GKE). Standard namespace-scoped NetworkPolicies are the appropriate tool for a layered product. Note that cluster admins can still layer ANP/BANP on top of RHDH's standard NetworkPolicies to make policies more or less restrictive as needed, but that is outside RHDH's scope.

### Alternative 6: Rely solely on documentation and leave NetworkPolicies to the user
- **Approach**: Document recommended NetworkPolicies without shipping them
- **Rejected because**: This puts the burden on every deployer to understand RHDH traffic patterns and write correct policies. Most users would not implement them, leaving deployments unprotected. Shipping sensible defaults with the ability to customize is a better security posture.

## Consequences

### Positive
- ✅ Enforces least-privilege network access by default, reducing the attack surface for RHDH deployments
- ✅ Addresses the risk identified in the OCP Threat Model ([OCPSTRAT-819](https://redhat.atlassian.net/browse/OCPSTRAT-819)) and meets the OCP 5+ requirement for shipping NetworkPolicies with operator-managed workloads
- ✅ Works transparently on OCP, which enforces NetworkPolicies out of the box. No user action required
- ✅ Does not break deployments on clusters without NetworkPolicy enforcement (policies are created but simply not enforced by Kubernetes)
- ✅ Configurable. Users can extend and customize policies to fit their environment (airgapped, proxied, etc.)
- ✅ No CRD or API changes needed. Leverages the additive nature of Kubernetes NetworkPolicies, so extensibility comes for free
- ✅ Per-component policy granularity provides defense-in-depth (e.g., PostgreSQL locked down to minimal egress while the RHDH backend gets broader HTTPS access)

### Negative
- ❌ While the base policies allow broad HTTPS egress (port 443), users must create their own additional NetworkPolicies for site-specific egress on non-standard ports or protocols. This requires awareness and documentation
- ❌ Users on non-OCP platforms must ensure their CNI plugin supports NetworkPolicy enforcement. Otherwise, policies exist but provide no actual protection, which requires clear documentation to avoid a false sense of security
- ❌ Adds complexity to the Operator and Helm chart codebases. Policies must be kept in sync with any changes to RHDH pod labels, ports, or component architecture, and must account for configurable features (Lightspeed sidecars enabled by default, Orchestrator cross-namespace flows, external databases). Future changes to NetworkPolicies should remain aligned with the principles outlined in this ADR
- ❌ Requires testing across all supported platforms (OCP, EKS, AKS, GKE) and across deployment variants (with/without Lightspeed, Orchestrator, external database) to validate that policies do not inadvertently block legitimate traffic
- ❌ On clusters that enforce NetworkPolicies (e.g., OCP), upgrading to a version that ships these base policies will introduce a default-deny for RHDH pods. Existing deployments that rely on egress to endpoints not covered by the base policies (SCMs, auth providers, registries, etc.) will experience connectivity failures unless users create their own additive NetworkPolicies before or during the upgrade. This upgrade impact must be clearly communicated in release notes and migration guides, including ready-to-use NetworkPolicy templates for common egress scenarios and steps to verify connectivity after the upgrade

### Neutral
- ⚖️ On clusters where administrators purposely do not enforce NetworkPolicies (e.g., no NetworkPolicy-capable CNI plugin configured), these policies will have no effect at all. The policies are created but not enforced, so existing behavior is completely unchanged
- ⚖️ OLM-managed NetworkPolicies for the operator pod itself remain out of scope until OLM support is backported ([RHDHPLAN-351](https://redhat.atlassian.net/browse/RHDHPLAN-351))
- ⚖️ Container image pulls happen at the container runtime level and are not affected by NetworkPolicies, which only govern pod-to-pod networking
- ⚖️ The RHDH must-gather should be updated to collect NetworkPolicies in place, so as to help troubleshoot potential connectivity failures caused by overly restrictive or misconfigured policies

## References

- [Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [OpenShift NetworkPolicy documentation](https://docs.openshift.com/container-platform/4.18/networking/network_security/network_policy/about-network-policy.html)
- [Best Practices for developing Network Policies](https://docs.google.com/document/d/1CDoGSRd-h8VT4PMrK_83Ro0YzYPjORbkxtfTJU1sN6Q/edit?tab=t.0)
- [OCPSTRAT-819: Protect from unintended data leaks / attacks via tailored Network Policies](https://redhat.atlassian.net/browse/OCPSTRAT-819)
- [RHDHPLAN-1032: Add tailored NetworkPolicies to the Install Methods](https://redhat.atlassian.net/browse/RHDHPLAN-1032)
- [RHDHPLAN-351: NetworkPolicies for the RHDH Operator itself (OLM-managed)](https://redhat.atlassian.net/browse/RHDHPLAN-351)
- [Slack discussion: ANP clarification with OCP team](https://redhat-internal.slack.com/archives/C06UYJ1K941/p1782138704901079)
