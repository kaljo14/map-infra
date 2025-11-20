# Deployment Guide

This guide walks you through deploying an application with Envoy authentication to your K3s cluster.

## Prerequisites Checklist

- [ ] K3s cluster is running
- [ ] `kubectl` is configured and can access the cluster
- [ ] Keycloak is deployed and accessible
- [ ] You have admin access to Keycloak
- [ ] You have your application container image ready

## Step-by-Step Deployment

### 1. Configure Keycloak

Follow the instructions in [`keycloak/client-config.md`](keycloak/client-config.md) to:
- Create a new client in Keycloak
- Configure the client settings
- Add the audience mapper
- Get the JWKS URI

### 2. Update Envoy Configuration

Edit `envoy/envoy-config.yaml` and replace the following placeholders:

```yaml
# Line 35-36: Update issuer and JWKS URI
issuer: "https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM"

# Line 38: Update audience
audiences:
- "YOUR_CLIENT_ID"

# Line 40-41: Update JWKS URI
uri: "https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM/protocol/openid-connect/certs"

# Line 76: Update your application port
port_value: 3000  # Your application port

# Line 85-87: Update Keycloak service address
address: YOUR_KEYCLOAK_SERVICE_NAME.YOUR_NAMESPACE.svc.cluster.local
port_value: 8080

# Line 92: Update SNI
sni: YOUR_KEYCLOAK_URL
```

**Example values:**
- `YOUR_KEYCLOAK_URL`: `keycloak.example.com` or `keycloak.default.svc.cluster.local`
- `YOUR_REALM`: `myrealm`
- `YOUR_CLIENT_ID`: `my-app-client`
- `YOUR_KEYCLOAK_SERVICE_NAME`: `keycloak`
- `YOUR_NAMESPACE`: `default`

### 3. Deploy Envoy ConfigMap

```bash
kubectl apply -f envoy/envoy-config.yaml
```

Verify the ConfigMap was created:
```bash
kubectl get configmap envoy-config
kubectl describe configmap envoy-config
```

### 4. Prepare Your Application Deployment

Choose one of the example deployments or create your own:

**Option A: Use a sample deployment**
```bash
# For Node.js
kubectl apply -f examples/nodejs-example-deployment.yaml

# For Python
kubectl apply -f examples/python-example-deployment.yaml

# Generic sample
kubectl apply -f examples/sample-app-deployment.yaml
```

**Option B: Create your own**

Copy one of the examples and modify:
1. Update the application container image
2. Adjust the application port (must match Envoy config)
3. Update environment variables
4. Adjust resource limits
5. Update health check endpoints

### 5. Deploy Your Application

```bash
kubectl apply -f your-deployment.yaml
```

### 6. Verify Deployment

Check pod status:
```bash
kubectl get pods -l app=your-app-name
```

You should see 2/2 containers running:
```
NAME                          READY   STATUS    RESTARTS   AGE
your-app-xxxxxxxxx-xxxxx      2/2     Running   0          30s
```

Check logs:
```bash
# Envoy logs
kubectl logs -l app=your-app-name -c envoy

# Application logs
kubectl logs -l app=your-app-name -c app
```

### 7. Test Authentication

#### Get a JWT Token from Keycloak

```bash
TOKEN=$(curl -s -X POST \
  'https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=YOUR_CLIENT_ID' \
  -d 'username=YOUR_USERNAME' \
  -d 'password=YOUR_PASSWORD' \
  -d 'grant_type=password' | jq -r '.access_token')

echo $TOKEN
```

#### Test Without Token (Should Fail)

```bash
kubectl port-forward svc/your-app-name 8080:80

curl -v http://localhost:8080/
# Expected: 401 Unauthorized
```

#### Test With Valid Token (Should Succeed)

```bash
curl -v -H "Authorization: Bearer $TOKEN" http://localhost:8080/
# Expected: 200 OK with response from your application
```

### 8. Expose Your Application (Optional)

#### Option A: NodePort (for testing)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: your-app-nodeport
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080  # Choose a port between 30000-32767
  selector:
    app: your-app-name
```

#### Option B: LoadBalancer (if supported)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: your-app-lb
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: your-app-name
```

#### Option C: Ingress (recommended for production)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: your-app-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # If using cert-manager
spec:
  ingressClassName: traefik  # K3s default
  rules:
  - host: your-app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: your-app-name
            port:
              number: 80
  tls:
  - hosts:
    - your-app.example.com
    secretName: your-app-tls
```

## Troubleshooting

### Pod Not Starting

```bash
kubectl describe pod -l app=your-app-name
kubectl logs -l app=your-app-name -c envoy --previous
```

Common issues:
- ConfigMap not found: Ensure `envoy-config` ConfigMap exists
- Image pull errors: Check image name and registry access
- Resource limits: Adjust CPU/memory requests and limits

### 401 Unauthorized Errors

1. **Check Envoy logs:**
   ```bash
   kubectl logs -l app=your-app-name -c envoy | grep -i jwt
   ```

2. **Verify token:**
   ```bash
   echo $TOKEN | cut -d. -f2 | base64 -d | jq
   ```
   
   Check:
   - `iss` (issuer) matches Envoy config
   - `aud` (audience) matches Envoy config
   - `exp` (expiration) is in the future

3. **Test JWKS endpoint:**
   ```bash
   curl https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM/protocol/openid-connect/certs
   ```

### Envoy Can't Reach Keycloak

1. **Test DNS resolution:**
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup keycloak.default.svc.cluster.local
   ```

2. **Test connectivity:**
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl -v http://keycloak.default.svc.cluster.local:8080
   ```

3. **Check Keycloak service:**
   ```bash
   kubectl get svc keycloak
   kubectl get endpoints keycloak
   ```

### Application Not Receiving Requests

1. **Check application is listening:**
   ```bash
   kubectl exec -it deployment/your-app-name -c app -- netstat -tlnp
   ```

2. **Verify port configuration:**
   - Application listens on port 3000 (or your configured port)
   - Envoy forwards to 127.0.0.1:3000
   - Service targets Envoy port 8080

3. **Test application directly:**
   ```bash
   kubectl port-forward deployment/your-app-name 3000:3000
   curl http://localhost:3000/health
   ```

## Scaling

Scale your deployment:
```bash
kubectl scale deployment your-app-name --replicas=3
```

## Updating Configuration

After updating Envoy config:
```bash
kubectl apply -f envoy/envoy-config.yaml
kubectl rollout restart deployment your-app-name
```

## Cleanup

Remove all resources:
```bash
kubectl delete -f your-deployment.yaml
kubectl delete configmap envoy-config
```
