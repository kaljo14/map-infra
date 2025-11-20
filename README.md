# Envoy + Keycloak Authentication Setup for K3s

Production-ready Kubernetes setup for deploying applications with Envoy sidecar authentication using Keycloak.

## Services

This repository includes configurations for:
1. **Tileserver** - Serves vector tiles at `tiles.mustaci.com`
2. **Places Scraper** - API for places data at `places-scraper.mustaci.com`
3. **Frontend** - Main application at `mustaci.com`

## Architecture

```
User Request 
  ↓
[ Traefik Ingress (TLS) ]
  ↓
[ Service (Port 80) ]
  ↓
[ Pod ]
  ├── Envoy Sidecar (Port 8000) ← EXPOSED
  │    ├── JWT Auth (Keycloak)
  │    ├── RBAC (Role Check)
  │    └── Router
  │
  └── Application Container (Port 3000/8080) ← HIDDEN
```

## Configuration

- **Keycloak Domain**: `keycloack.mustaci.com`
- **Realm**: `barbershop-realm`
- **Client**: `barbershop-app`

## Quick Start

### 1. Configure Keycloak
Follow [keycloak/roles-setup.md](keycloak/roles-setup.md) and [keycloak/client-config.md](keycloak/client-config.md).

### 2. Deploy

```bash
kubectl apply -k .
```

## Directory Structure

```
.
├── apps/
│   ├── tileserver/
│   │   ├── envoy-config.yaml
│   │   ├── deployment.yaml
│   │   └── ingress.yaml
│   └── places-scraper/
│       ├── envoy-config.yaml
│       ├── deployment.yaml
│       └── ingress.yaml
├── keycloak/
│   ├── client-config.md
│   └── roles-setup.md
├── kustomization.yaml
└── README.md
```

## Roles

- **admin**: Full access to all services
- **map-viewer**: Read-only access to tiles
- **data-viewer**: Read-only access to places data
- **data-editor**: Create, update, delete places data
