# Deployment Guide

This guide walks you through deploying an application with Envoy authentication to your K3s cluster.

## Prerequisites Checklist

- [ ] K3s cluster is running
- [ ] `kubectl` is configured and can access the cluster
- [ ] Clerk application is set up with a JWT template exposing `role` claim
- [ ] You have your application container image ready

## Step-by-Step Deployment

### 1. Configure Clerk

In the Clerk Dashboard:
1. Create a JWT Template that includes `user.publicMetadata.role` as a `role` claim
2. Assign roles to users via `publicMetadata.role` (values: `map-viewer`, `admin`, `data-viewer`, `data-editor`)
3. Note your Clerk domain (e.g., `clerk.lonctus.com`)

### 2. Update Envoy Configuration

Edit the relevant `envoy-config.yaml` and update:

```yaml
# Issuer — your Clerk domain
issuer: "https://clerk.lonctus.com"

# JWKS endpoint
uri: "https://clerk.lonctus.com/.well-known/jwks.json"

# Cluster address
address: clerk.lonctus.com
port_value: 443
```

The Envoy cluster must use `LOGICAL_DNS` type with TLS (`UpstreamTlsContext` + `sni`) since Clerk is an external HTTPS endpoint.

### 3. Deploy

```bash
kubectl apply -k .
```

Verify the deployment:
```bash
kubectl get pods -n map
```

You should see 2/2 containers running for each service (Envoy + app).

### 4. Test Authentication

#### Get a Clerk Token

Sign in at lonctus.com, open browser devtools, and run:
```javascript
await window.Clerk.session.getToken()
```

#### Test Without Token (Should Fail)

```bash
curl -v https://martin.lonctus.com/
# Expected: 401 Unauthorized
```

#### Test With Valid Token (Should Succeed)

```bash
curl -v -H "Authorization: Bearer $TOKEN" https://martin.lonctus.com/
# Expected: 200 OK
```

## Troubleshooting

### Pod Not Starting

```bash
kubectl describe pod -l app=your-app-name -n map
kubectl logs -l app=your-app-name -n map -c envoy --previous
```

Common issues:
- ConfigMap not found: Ensure envoy-config ConfigMap exists
- Image pull errors: Check image name and registry access

### 401 Unauthorized Errors

1. **Check Envoy logs:**
   ```bash
   kubectl logs -l app=your-app-name -n map -c envoy | grep -i jwt
   ```

2. **Verify token:**
   ```bash
   echo $TOKEN | cut -d. -f2 | base64 -d | jq
   ```

   Check:
   - `iss` (issuer) matches `https://clerk.lonctus.com`
   - `exp` (expiration) is in the future
   - `role` claim is present (if RBAC is enabled)

3. **Test JWKS endpoint:**
   ```bash
   curl https://clerk.lonctus.com/.well-known/jwks.json
   ```

### Envoy Can't Reach Clerk JWKS

1. **Test DNS resolution from a pod:**
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup clerk.lonctus.com
   ```

2. **Test HTTPS connectivity:**
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl -v https://clerk.lonctus.com/.well-known/jwks.json
   ```

3. **Check if CoreDNS forwards external queries:**
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml
   ```

### Application Not Receiving Requests

1. **Verify port configuration:**
   - Application listens on its configured port (3000 or 8080)
   - Envoy forwards to 127.0.0.1:<app-port>
   - Service targets Envoy port 8000

2. **Test application directly:**
   ```bash
   kubectl port-forward deployment/your-app-name 3000:3000 -n map
   curl http://localhost:3000/health
   ```

## Updating Configuration

After updating Envoy config:
```bash
kubectl apply -k .
kubectl rollout restart deployment <deployment-name> -n map
```
