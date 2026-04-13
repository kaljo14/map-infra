# Envoy + Clerk Authentication Setup for K3s

Production-ready Kubernetes setup for deploying applications with Envoy sidecar authentication using Clerk.

## Services

This repository includes configurations for:
1. **Tileserver** - Serves vector tiles at `tiles.lonctus.com`
2. **Places Scraper** - API for places data at `places-scraper.lonctus.com`
3. **Martin** - Vector tile server at `martin.lonctus.com`
4. **Frontend** - Main application at `lonctus.com`

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
  │    ├── JWT Auth (Clerk)
  │    ├── RBAC (Role Check)
  │    └── Router
  │
  └── Application Container (Port 3000/8080) ← HIDDEN
```

## Configuration

- **Clerk Domain**: `clerk.lonctus.com`
- **JWKS Endpoint**: `https://clerk.lonctus.com/.well-known/jwks.json`
- **Roles**: Set via Clerk `publicMetadata.role` and exposed as `role` claim in JWT template

## Quick Start

### 1. Configure Clerk

1. Create a JWT Template in Clerk Dashboard that exposes `user.publicMetadata.role` as a `role` claim
2. Set `publicMetadata.role` on users (`map-viewer`, `admin`, `data-viewer`, `data-editor`)

### 2. Deploy

```bash
kubectl apply -k .
```

## Directory Structure

```
.
├── apps/
│   ├── frontend/
│   │   ├── deployment.yaml
│   │   └── ingress.yaml
│   ├── tileserver/
│   │   ├── envoy-config.yaml
│   │   ├── deployment.yaml
│   │   └── ingress.yaml
│   ├── places-scraper/
│   │   ├── envoy-config.yaml
│   │   ├── deployment.yaml
│   │   └── ingress.yaml
│   └── martin/
│       ├── envoy-config.yaml
│       ├── deployment.yaml
│       └── ingress.yaml
├── kustomization.yaml
└── README.md
```

## Roles

- **admin**: Full access to all services
- **map-viewer**: Read-only access to tiles
- **data-viewer**: Read-only access to places data
- **data-editor**: Create, update, delete places data
