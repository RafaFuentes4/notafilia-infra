# notafilia-infra

Kubernetes infrastructure for [Notafilia](https://github.com/RafaFuentes4/notafilia) — a Django application deployed to OVH Managed Kubernetes using a modern GitOps stack.

**Live**: [https://notafilia.es](https://notafilia.es) | [https://staging.notafilia.es](https://staging.notafilia.es)

## Stack

| Layer | Tool |
|-------|------|
| GitOps | ArgoCD |
| App manifests | Kustomize (plain YAML + overlays) |
| Infrastructure | Helm (third-party charts only) |
| Ingress | Traefik + Gateway API |
| TLS | cert-manager + Let's Encrypt |
| Secrets | SOPS + age |
| PostgreSQL | CloudNativePG operator |
| Redis | Official redis:7-alpine |
| CI/CD | GitHub Actions → GHCR |
| Cluster | OVH Managed Kubernetes (GRA9, 2× B3-8) |

## Repository Structure

```
notafilia-infra/
├── base/                          # Kustomize base (app manifests)
│   ├── kustomization.yaml
│   ├── deployment-web.yaml        # Gunicorn + migrate init container
│   ├── deployment-celery.yaml     # Celery worker
│   ├── deployment-beat.yaml       # Celery beat (Recreate strategy)
│   ├── service-web.yaml           # ClusterIP:8000
│   ├── configmap.yaml             # Non-secret env vars
│   └── httproute.yaml             # Gateway API route
├── overlays/
│   ├── staging/                   # namespace: staging, host: staging.notafilia.es
│   └── production/                # namespace: production, host: notafilia.es
├── infrastructure/                # Third-party services (ArgoCD Applications)
│   ├── traefik/                   # Traefik v3 + Gateway API + LoadBalancer
│   ├── cert-manager/              # cert-manager + ClusterIssuer + Certificate
│   ├── cloudnative-pg/            # CNPG operator + PG clusters per environment
│   └── redis/                     # redis:7-alpine per environment
├── argocd/                        # App-of-apps bootstrap
│   ├── app-of-apps.yaml           # Root Application → manages everything
│   ├── infrastructure.yaml        # Deploys all infra services
│   ├── staging.yaml               # Deploys app to staging
│   └── production.yaml            # Deploys app to production
├── .sops.yaml                     # SOPS age encryption config
└── docs/
    ├── progress.md                # Complete setup guide (recreate from scratch)
    ├── learning-guide.md          # K8s concepts explained for junior engineers
    └── implementation-spec.md     # Original spec (historical reference)
```

## Quick Start

```bash
# Prerequisites
brew install kubectl argocd helm sops age kustomize

# Validate manifests locally
kubectl kustomize overlays/staging
kubectl kustomize overlays/production

# Deploy (after cluster is ready + ArgoCD installed)
kubectl apply -f argocd/app-of-apps.yaml
```

## Documentation

| Doc | Purpose |
|-----|---------|
| **[Setup Guide](docs/progress.md)** | Step-by-step guide to recreate the entire infrastructure from scratch |
| **[Learning Guide](docs/learning-guide.md)** | K8s concepts explained with real examples from this project |
| **[Implementation Spec](docs/implementation-spec.md)** | Original planning spec (historical reference) |

## App Components

Three deployments from a single Docker image (`Dockerfile.web`):

| Component | Command | Replicas |
|-----------|---------|----------|
| **web** | `gunicorn --bind 0.0.0.0:8000 --workers 1 --threads 8 --timeout 0 notafilia.wsgi:application` | 1 |
| **celery** | `celery -A notafilia worker -l INFO --pool threads --concurrency 20` | 1 |
| **beat** | `celery -A notafilia beat -l INFO` | 1 (always, Recreate strategy) |

Migrations run as an init container on the web deployment.

## Architecture

```
Internet → DNS (notafilia.es / staging.notafilia.es)
  → OVH LoadBalancer (57.128.58.136:443)
    → Traefik (TLS termination via Let's Encrypt cert)
      → Gateway API HTTPRoute (host-based routing)
        → notafilia-web Service → Gunicorn pods
```

## Common Operations

```bash
# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# View logs
kubectl logs -n staging -l app.kubernetes.io/component=web -c web --tail=50

# Run Django management commands
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py <command>

# Connect to PostgreSQL
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432
psql -h 127.0.0.1 -p 5433 -U notafilia -d notafilia

# Check all ArgoCD app statuses
kubectl get applications -n argocd
```
