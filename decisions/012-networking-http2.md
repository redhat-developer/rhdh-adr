# ADR: Unified Networking and HTTP/2 Support

## Context

**Problem**: RHDH frontend startup time grows significantly with larger plugin counts (40+ plugins). The number of frontend assets (JavaScript bundles, CSS) increases with each plugin, and the Backstage New Frontend System (NFS) further increases asset count. With HTTP/1.1, browsers are limited to ~6 concurrent connections per domain, causing sequential loading and slower page render times.

HTTP/2 provides significant performance benefits through:
- **Multiplexing**: Multiple requests over a single TCP connection
- **Header compression**: Reduced overhead with HPACK
- **No head-of-line blocking**: Independent streams at HTTP level

**Platform constraints:**

**OpenShift:**
- HTTP/2 requires cluster-admin to enable at IngressController level (cluster-wide)
- Custom certificate required (default wildcard certificate blocks HTTP/2 due to connection coalescing)
- No per-route control

**Vanilla Kubernetes:**
- **Traefik**: HTTP/2 enabled by default with TLS
- **Caddy**: HTTP/2 enabled by default with TLS
- **NGINX Ingress Controller**: HTTP/2 disabled by default, requires cluster-admin to enable via ConfigMap (cluster-wide)
- **HAProxy**: Depends on configuration

On both platforms, RHDH users on shared clusters cannot enable HTTP/2 without cluster-admin cooperation.

## Decision

Introduce unified networking configuration for both OpenShift (Route) and vanilla Kubernetes (Ingress), with HTTP/2 proxy support:

- **OpenShift**: Provide optional sidecar proxy that handles TLS termination and HTTP/2, allowing users to enable HTTP/2 without cluster-admin privileges
- **Vanilla Kubernetes**: Add Ingress configuration; sidecar provides HTTP/2 without cluster-admin dependency (similar benefit as OpenShift)

**Implementation approach**:

1. **Add optional HTTP/2 proxy sidecar container** to Backstage deployment:
   - Lightweight reverse proxy (e.g., NGINX, Envoy, Caddy) configured for HTTP/2 and TLS termination
   - Proxies requests to Backstage on localhost:7007
   - Mounts TLS certificates from Secret
   - Can add caching headers for static assets (e.g., `/api/scalprum/*/static/*.js`) — reduces repeat downloads on subsequent page loads — see [POC](https://github.com/karthikjeeyar/rhdh-http2)

2. **Use passthrough termination** (when `http2Proxy` enabled):

   **OpenShift Route:**
   ```yaml
   apiVersion: route.openshift.io/v1
   kind: Route
   spec:
     tls:
       termination: passthrough
     port:
       targetPort: https
   ```

   **Kubernetes Ingress** (if http2Proxy used): Configure Ingress controller for SSL passthrough to let the sidecar handle HTTP/2 termination.

3. **Certificate provisioning options**:
   - OpenShift service serving certificates (annotation-based, auto-rotated, but causes browser warnings — internal CA)
   - cert-manager with Let's Encrypt (public CA, no browser warnings)
   - User-provided certificates via Secret

4. **Expose via `spec.network`**:

   **OpenShift (Route):**
   ```yaml
   spec:
     network:
       route:
         enabled: true
         host: my-backstage.example.com
         tls:
           externalCertificateSecretName: my-tls
       http2Proxy:
         enabled: true  # required for HTTP/2 on OpenShift without cluster-admin
   ```

   **Vanilla Kubernetes (Ingress):**
   ```yaml
   spec:
     network:
       ingress:
         enabled: true
         host: my-backstage.example.com
         className: <ingress-class>  # optional
         tls:
           secretName: my-tls
       http2Proxy:
         enabled: true  # enables HTTP/2 without cluster-admin (NGINX Ingress also requires cluster-admin to enable HTTP/2)
   ```

   - `spec.network.route` — moved from `spec.application.route` (deprecated, supported with warning)
   - `spec.network.ingress` — new, for vanilla Kubernetes deployments
   - `spec.network.http2Proxy.enabled` — adds sidecar; switches Route to passthrough / configures Ingress for SSL passthrough
   - Certificate reuse: when `http2Proxy.enabled`, proxy uses `route.tls` or `ingress.tls` certificate; defaults to service serving certificates if not specified

   **Note:** The `http2Proxy` sidecar provides HTTP/2 support without cluster-admin cooperation on both OpenShift and Kubernetes (where NGINX Ingress Controller also requires cluster-admin to enable HTTP/2).

5. **Default behavior considerations**:

   Enabling `http2Proxy` by default is possible but has UX trade-offs:
   - **Without user-provided certificate**: Uses OpenShift service serving certificates (internal CA) — HTTP/2 works but browsers show certificate warning
   - **With user-provided certificate**: No warnings, full HTTP/2 benefits

   **Options:**
   - `http2Proxy.enabled: false` by default — users opt-in, no surprises
   - `http2Proxy.enabled: true` by default — HTTP/2 out of the box, but certificate warning unless user provides `route.tls.externalCertificateSecretName`

   If decided to default to `enabled: true`: provide clear documentation that users should supply their own certificate to avoid browser warnings. The performance benefit may justify the default, and the warning serves as a signal to configure properly.

## Alternatives Considered

### Alternative 1: Document cluster-admin HTTP/2 enablement
- **Approach**: Document how cluster-admins can enable HTTP/2 and require custom certificates per-route
- **Rejected because**: Users on shared clusters have no control; requires coordination with cluster-admin for each deployment; doesn't solve the core user autonomy problem

### Alternative 2: Standalone HTTP/2 proxy Deployment
- **Approach**: Deploy NGINX/Envoy as separate Deployment + Service; Route/Ingress points to proxy, proxy routes to Backstage Service
- **Rejected because**: Single point of failure; extra network hop adds latency; doesn't scale automatically with Backstage replicas; more complex Service topology to manage

## Consequences

### Positive
✅ Sidecar approach enables HTTP/2 without cluster-admin privileges (bypasses Ingress controller limitations)
✅ Faster frontend page loads (multiplexing, reduced connections)
✅ Works on any OpenShift/Kubernetes cluster
✅ Lightweight proxy sidecars have minimal resource footprint
✅ Works correctly with multi-replica deployments (sidecar per pod)

### Negative
❌ HTTP/2 not available by default — requires user to provide certificate to avoid browser warnings
❌ Additional container per pod (slight resource overhead)
❌ Users must manage TLS certificates (unless accepting browser warnings with service serving certs)
❌ More complex deployment architecture to understand/debug
❌ Proxy configuration must be maintained by operator

## References

**Related issues:**
- [RHDHSUPP-320](https://redhat.atlassian.net/browse/RHDHSUPP-320)
- [RHDHPLAN-1598](https://redhat.atlassian.net/browse/RHDHPLAN-1598)
- [POC: rhdh-http2](https://github.com/karthikjeeyar/rhdh-http2)

**Documentation:**
- [FAQ: Does OpenShift Router support HTTP/2](https://docs.google.com/document/d/1S6E_sSmtxHknoVNBzW36q5Q-SHssbNFGWSWL3cwNEeo/edit?tab=t.0#heading=h.renxd4iwgobg)
- [Red Hat Blog: gRPC or HTTP/2 Ingress Connectivity in OpenShift](https://www.redhat.com/en/blog/grpc-or-http/2-ingress-connectivity-in-openshift)
- [OpenShift Docs: Configuring Routes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/networking/configuring-routes)
- [NGINX Ingress Controller: ConfigMap HTTP/2 Setting](https://docs.nginx.com/nginx-ingress-controller/configuration/global-configuration/configmap-resource/#listeners)
- [HTTP/2 connection coalescing explanation](https://daniel.haxx.se/blog/2016/08/18/http2-connection-coalescing/)
