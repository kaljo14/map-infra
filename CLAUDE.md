# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kubernetes infrastructure-as-code for **mustaci.com** — a barbershop mapping application. Three services (frontend, tileserver, places-scraper) managed via Kustomize, with Envoy sidecar proxies providing JWT authentication (via Keycloak) and RBAC.

## Commands

**Deploy entire stack:**
```bash
kubectl apply -k .
```

**Preview generated manifests:**
```bash
kubectl kustomize .
```

**Check deployment status:**
```bash
kubectl get pods -n map
kubectl get ingress -n map
```

**Debug Envoy sidecar logs:**
```bash
kubectl logs <pod-name> -n map -c envoy
```

**Get a Keycloak token for testing:**
```bash
TOKEN=$(curl -s -X POST 'https://keycloak.mustaci.com/realms/barbershop-realm/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=barbershop-app' \
  -d 'username=USERNAME' \
  -d 'password=PASSWORD' \
  -d 'grant_type=password' | jq -r '.access_token')
```

## Architecture

```
HTTPS Request
  → Traefik Ingress (TLS via cert-manager / Let's Encrypt)
  → Kubernetes Service (ClusterIP :80)
  → Envoy sidecar (:8000)  ← JWT validation + RBAC
  → App container (localhost only)
```

All protected services expose only the Envoy port externally; app containers bind to `127.0.0.1` and are unreachable without going through Envoy.

### Services

| Service | Domain | App Port | Roles |
|---------|--------|----------|-------|
| Frontend | mustaci.com | 80 | Public (no Envoy) |
| Tileserver | tiles.mustaci.com | 8080 | `map-viewer`, `admin` |
| Places Scraper | places-scraper.mustaci.com | 3000 | `data-viewer` (GET), `data-editor` (POST/PUT/DELETE), `admin` |

### Authentication Flow

- Keycloak realm: `barbershop-realm`, client: `barbershop-app`
- External issuer: `https://keycloak.mustaci.com/realms/barbershop-realm`
- Internal JWKS fetch: `http://keycloak.default.svc.cluster.local/realms/barbershop-realm/protocol/openid-connect/certs`
- JWKS cache TTL: 300s

## Repository Layout

```
kustomization.yaml          # Root Kustomize entrypoint — lists all resources
apps/
  frontend/
    deployment.yaml         # Deployment + Service
    ingress.yaml
  tileserver/
    deployment.yaml
    envoy-config.yaml       # JWT auth + RBAC rules (ConfigMap)
    ingress.yaml
    storage.yaml            # 2Gi PVC for tile data
    job.yaml                # One-off tile generation job
  places-scraper/
    deployment.yaml
    envoy-config.yaml
    ingress.yaml
keycloak/
  roles-setup.md            # How to configure Keycloak roles
  client-config.md          # How to configure the OAuth2 client
DEPLOYMENT.md               # Full deployment guide and troubleshooting
```

Each `envoy-config.yaml` is a ConfigMap with a `envoy.yaml` key mounted into the Envoy container. Changing auth rules (roles, routes) means editing those ConfigMaps and re-applying.

## Key Conventions

- **Namespace**: `map` for tileserver and places-scraper; frontend currently uses `default`.
- **Envoy version**: v1.29 (`envoyproxy/envoy:v1.29.x`).
- **Ingress**: Traefik — annotations in `ingress.yaml` control TLS class and cert-manager issuer.
- **Images**: `kaljo14/my-map:latest`, `kaljo14/places-scraper:latest`, `maptiler/tileserver-gl:latest`.
