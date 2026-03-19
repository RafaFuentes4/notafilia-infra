# notafilia-infra

Kubernetes infrastructure for [Notafilia](https://github.com/RafaFuentes4/notafilia) — a Django application deployed to OVH Managed Kubernetes using a modern GitOps stack.

## Stack

| Layer | Tool |
|-------|------|
| GitOps | ArgoCD |
| App manifests | Kustomize |
| Infrastructure charts | Helm |
| Ingress | Traefik + Gateway API |
| TLS | cert-manager + Let's Encrypt |
| Secrets | SOPS + age |
| PostgreSQL | CloudNativePG |
| Redis | Bitnami Helm chart |
| CI/CD | GitHub Actions + GHCR |
| Cluster | OVH Managed Kubernetes |

## Repository Structure

```
notafilia-infra/
├── base/                          # Kustomize base (app manifests)
│   ├── kustomization.yaml
│   ├── deployment-web.yaml
│   ├── deployment-celery.yaml
│   ├── deployment-beat.yaml
│   ├── service-web.yaml
│   ├── configmap.yaml
│   └── httproute.yaml
├── overlays/
│   ├── staging/
│   │   ├── kustomization.yaml
│   │   └── secrets.enc.yaml      # SOPS-encrypted
│   └── production/
│       ├── kustomization.yaml
│       └── secrets.enc.yaml
├── infrastructure/                # Third-party services (ArgoCD Applications)
│   ├── traefik/
│   ├── cert-manager/
│   ├── cloudnative-pg/
│   └── redis/
├── argocd/                        # App-of-apps bootstrap
│   ├── app-of-apps.yaml
│   ├── infrastructure.yaml
│   ├── staging.yaml
│   └── production.yaml
├── docs/
│   ├── implementation-spec.md     # Full spec with file contents and commands
│   └── learning-guide.md          # Per-phase learning objectives and links
├── .sops.yaml
└── README.md
```

## Implementation Phases

| Phase | What | Depends on |
|-------|------|------------|
| 1. Repo + Tooling | Create all manifests, verify locally | Nothing |
| 2. OVH Cluster | Provision cluster, install CLI tools | Phase 1 |
| 3. ArgoCD + Infra | Install ArgoCD, deploy Traefik/cert-manager/CNPG/Redis | Phase 2 |
| 4. App Deploy | Encrypt secrets, deploy staging | Phase 3 |
| 5. CI/CD | GitHub Actions workflow for automated builds | Phase 4 |
| 6. Production | Production secrets, DNS, TLS | Phase 5 |

## Quick Start

### Prerequisites

```bash
brew install kubectl argocd helm sops age kustomize
```

### Validate manifests locally

```bash
kubectl kustomize overlays/staging
kubectl kustomize overlays/production
```

### Encrypt secrets

```bash
# Generate age key (once)
age-keygen -o ~/.config/sops/age/keys.txt

# Encrypt a secrets file
sops -e -i overlays/staging/secrets.enc.yaml

# Edit encrypted secrets
sops overlays/staging/secrets.enc.yaml
```

### Deploy

```bash
# 1. Install ArgoCD on your cluster
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Apply the root app-of-apps (bootstraps everything)
kubectl apply -f argocd/app-of-apps.yaml

# 3. Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
```

## Documentation

- **[Implementation Spec](docs/implementation-spec.md)** — Detailed steps, commands, and complete file contents for every phase.
- **[Learning Guide](docs/learning-guide.md)** — K8s concepts to study per phase, official doc links, debugging commands, and glossary.

## App Components

The Notafilia app runs as three deployments from a single Docker image (`Dockerfile.web`):

| Component | Command | Replicas |
|-----------|---------|----------|
| **web** | `gunicorn --bind 0.0.0.0:8000 --workers 1 --threads 8 --timeout 0 notafilia.wsgi:application` | 1 (staging) / 2 (prod) |
| **celery** | `celery -A notafilia worker -l INFO --pool threads --concurrency 20` | 1 |
| **beat** | `celery -A notafilia beat -l INFO` | 1 (always) |

Migrations run as an init container on the web deployment.
