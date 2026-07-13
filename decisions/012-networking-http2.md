# ADR: Unified Networking and HTTP/2 Support

## Context

**Problem**: RHDH frontend startup time grows significantly with larger plugin counts (40+ plugins). The number of frontend assets (JavaScript bundles, CSS) increases with each plugin, and the Backstage New Frontend System (NFS) further increases asset count. With HTTP/1.1, browsers are limited to ~6 concurrent connections per domain, causing sequential loading and slower page render times.

HTTP/2 provides significant performance benefits through:
- **Multiplexing**: Multiple requests over a single TCP connection
- **Header compression**: Reduced overhead with HPACK
- **No head-of-line blocking**: Independent streams at HTTP level

**Platform differences:**

**OpenShift** has significant constraints:
1. **Cluster-admin requirement**: HTTP/2 must be enabled at the IngressController level (each HAProxy instance) or cluster-wide (for all HAProxy instances):
   ```sh
   oc annotate ingresses.config/cluster ingress.operator.openshift.io/default-enable-http2=true
   ```
2. **Custom certificate requirement**: OpenShift blocks HTTP/2 for routes using the default wildcard certificate (`*.apps.cluster.com`) to prevent connection coalescing issues.
3. **No per-route control**: There is no route-level annotation to enable HTTP/2; it's a cluster-wide decision.

This means RHDH users on shared OpenShift clusters cannot enable HTTP/2 without cluster-admin cooperation.

**Vanilla Kubernetes** is simpler — most Ingress controllers (NGINX, Traefik, HAProxy) support HTTP/2 by default when TLS is enabled. No special configuration required.

## Decision

Introduce unified networking configuration for both OpenShift (Route) and vanilla Kubernetes (Ingress), with HTTP/2 proxy support:

- **OpenShift**: Provide optional NGINX sidecar proxy that handles TLS termination and HTTP/2, allowing users to enable HTTP/2 without cluster-admin privileges
- **Vanilla Kubernetes**: Add Ingress configuration; most controllers support HTTP/2 natively with TLS, sidecar optional

**Implementation approach**:

1. **Add optional NGINX sidecar container** to Backstage deployment:
   ```yaml
   containers:
   - name: backstage
     image: backstage:latest
     ports:
     - containerPort: 7007

   - name: http2-proxy
     image: nginx:alpine
     ports:
     - containerPort: 8443
     volumeMounts:
     - name: tls
       mountPath: /etc/nginx/tls
     - name: nginx-config
       mountPath: /etc/nginx/conf.d
   ```

2. **NGINX configuration with HTTP/2**:
   ```nginx
   server {
       listen 8443 ssl http2;
       ssl_certificate /etc/nginx/tls/tls.crt;
       ssl_certificate_key /etc/nginx/tls/tls.key;

       location / {
           proxy_pass http://localhost:7007;
           proxy_http_version 1.1;
           proxy_set_header Host $host;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```

3. **Use passthrough termination** (when http2Proxy enabled):

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

   **Kubernetes Ingress** (if http2Proxy used): Configure Ingress controller for SSL passthrough, or use standard TLS termination since most controllers support HTTP/2 natively.

4. **Certificate provisioning options**:
   - OpenShift service serving certificates (annotation-based, auto-rotated, but causes browser warnings — internal CA)
   - cert-manager with Let's Encrypt (public CA, no browser warnings)
   - User-provided certificates via Secret

5. **Expose via `spec.network`**:

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
         className: nginx  # optional
         tls:
           secretName: my-tls
       http2Proxy:
         enabled: false  # usually not needed — most Ingress controllers support HTTP/2 natively
   ```

   - `spec.network.route` — moved from `spec.application.route` (deprecated, supported with warning)
   - `spec.network.ingress` — new, for vanilla Kubernetes deployments
   - `spec.network.http2Proxy.enabled` — adds NGINX sidecar; switches Route to passthrough / configures Ingress for SSL passthrough
   - Certificate reuse: when `http2Proxy.enabled`, proxy uses `route.tls` or `ingress.tls` certificate; defaults to service serving certificates if not specified

   **Note:** On vanilla Kubernetes, most Ingress controllers (NGINX, Traefik, HAProxy) support HTTP/2 by default when TLS is enabled. The `http2Proxy` sidecar is primarily needed for OpenShift where cluster-admin controls HTTP/2 at the IngressController level.

6. **Default behavior considerations**:

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

### Alternative 3: Modify Backstage/Node.js to serve HTTP/2 directly
- **Approach**: Configure Backstage's Node.js server to handle HTTP/2 and TLS
- **Rejected because**: Requires upstream Backstage changes; Node.js HTTP/2 is more complex than NGINX; certificate handling in Node.js is less mature

## Consequences

### Positive
✅ Users can enable HTTP/2 without cluster-admin privileges
✅ Faster frontend page loads (multiplexing, reduced connections)
✅ Works on any OpenShift/Kubernetes cluster
✅ NGINX is battle-tested, lightweight (~10MB RAM), and well-understood
✅ Optional feature - users who don't need HTTP/2 are unaffected
✅ Works correctly with multi-replica deployments (sidecar per pod)

### Negative
❌ Additional container per pod (slight resource overhead)
❌ Users must manage TLS certificates (unless using service serving certs)
❌ More complex deployment architecture to understand/debug
❌ NGINX configuration must be maintained by operator

### Neutral
⚖️ Changes Route from `edge` to `passthrough` termination when enabled (Ingress: depends on controller)
⚖️ HTTP/2 benefit depends on network conditions (may not help on lossy networks)
⚖️ Browser DevTools needed to verify HTTP/2 is active (Protocol column)

## References

- [Red Hat Blog: gRPC or HTTP/2 Ingress Connectivity in OpenShift](https://www.redhat.com/en/blog/grpc-or-http/2-ingress-connectivity-in-openshift)
- [OpenShift Docs: Configuring Routes](https://docs.openshift.com/container-platform/4.14/networking/routes/route-configuration.html)
- [HTTP/2 connection coalescing explanation](https://daniel.haxx.se/blog/2016/08/18/http2-connection-coalescing/)
