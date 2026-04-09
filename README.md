<div align="center">

# notafilia-infra

**Production Kubernetes infrastructure for [Notafilia](https://github.com/RafaFuentes4/notafilia) — a Django application deployed to OVH Managed Kubernetes using a full GitOps stack.**

*The cluster state is fully declarative and driven by this repository. No manual `kubectl apply`, no configuration drift.*

[![Production](https://img.shields.io/website?url=https%3A%2F%2Fnotafilia.es&label=production&style=for-the-badge&logo=kubernetes&logoColor=white&color=326CE5)](https://notafilia.es)
[![Staging](https://img.shields.io/website?url=https%3A%2F%2Fstaging.notafilia.es&label=staging&style=for-the-badge&logo=kubernetes&logoColor=white&color=6B7280)](https://staging.notafilia.es)

</div>

---

## Stack

<div align="center">

![ArgoCD](https://img.shields.io/badge/ArgoCD-EF7B4D?style=flat-square&logo=argo&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Kustomize](https://img.shields.io/badge/Kustomize-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Traefik](https://img.shields.io/badge/Traefik-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)
![cert-manager](https://img.shields.io/badge/cert--manager-003A9B?style=flat-square&logo=letsencrypt&logoColor=white)
![SOPS](https://img.shields.io/badge/SOPS-000000?style=flat-square&logo=gnuprivacyguard&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/CloudNativePG-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Redis](https://img.shields.io/badge/Redis-DC382D?style=flat-square&logo=redis&logoColor=white)
![Django](https://img.shields.io/badge/Django-092E20?style=flat-square&logo=django&logoColor=white)
![Celery](https://img.shields.io/badge/Celery-37814A?style=flat-square&logo=celery&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=flat-square&logo=githubactions&logoColor=white)
![OVH](https://img.shields.io/badge/OVH_Cloud-123F6D?style=flat-square&logo=ovh&logoColor=white)

</div>

| Concern | Tool | Why |
|---------|------|-----|
| GitOps controller | **ArgoCD** | App-of-apps pattern, self-healing, drift detection |
| App manifests | **Kustomize** | Plain YAML with environment overlays — no templating engine needed |
| Ingress | **Traefik v3 + Gateway API** | Modern routing standard, replaces legacy Ingress resource |
| TLS | **cert-manager + Let's Encrypt** | Fully automated certificate lifecycle |
| Secrets | **SOPS + age** | Value-level encryption in Git — safe to commit, no in-cluster controller needed |
| PostgreSQL | **CloudNativePG operator** | Production-grade PG on K8s with declarative lifecycle management |
| Async tasks | **Celery + Redis** | Worker and beat scheduler as separate Deployments |
| Media storage | **OVH Object Storage (S3-compatible)** | Offloaded from pods via django-storages |
| DB backups | **Barman → OVH S3** | Daily scheduled backups with retention policy |
| CI/CD | **GitHub Actions → GHCR** | Image built and pushed on merge to main |
| Cluster | **OVH Managed Kubernetes** (GRA9, B3-8) | Managed control plane, Cinder persistent volumes |

---

## Architecture

```mermaid
graph TD
    Internet([Internet]) --> DNS[DNS\nnotafilia.es / staging.notafilia.es]
    DNS --> LB[OVH LoadBalancer]
    LB --> Traefik[Traefik v3\nTLS termination]
    Traefik --> HTTPRoute[Gateway API HTTPRoute\nhost-based routing]
    HTTPRoute --> Web[notafilia-web\nGunicorn]

    Web --> PG[(CloudNativePG\nPostgreSQL)]
    Web --> Redis[(Redis 7)]
    Web --> S3[OVH Object Storage\nMedia files]

    PG --> Backup[Barman Backups\nOVH S3]

    subgraph GitOps
        GitHub[(GitHub\nnotafilia-infra)] --> ArgoCD[ArgoCD]
        ArgoCD -->|reconciles| HTTPRoute
        ArgoCD -->|reconciles| Web
        ArgoCD -->|reconciles| PG
        ArgoCD -->|reconciles| Redis
        ArgoCD -->|reconciles| Traefik
    end

    style GitOps fill:#f0f4ff,stroke:#326CE5
```

---

## Repository Structure

```
notafilia-infra/
├── base/                          # Kustomize base — shared app manifests
│   ├── deployment-web.yaml        # Gunicorn + Django migrate init container
│   ├── deployment-celery.yaml     # Async task worker
│   ├── deployment-beat.yaml       # Celery beat scheduler (Recreate strategy)
│   ├── service-web.yaml           # ClusterIP on port 8000
│   ├── configmap.yaml             # Non-secret environment variables
│   └── httproute.yaml             # Gateway API HTTPRoute (hostname overridden per env)
│
├── overlays/
│   ├── staging/                   # namespace: staging · host: staging.notafilia.es
│   │   ├── kustomization.yaml     # Patches + image tag
│   │   └── secrets.enc.yaml       # SOPS-encrypted secrets (safe to commit)
│   └── production/                # namespace: production · host: notafilia.es
│       ├── kustomization.yaml
│       └── secrets.enc.yaml
│
├── infrastructure/                # Third-party services as ArgoCD Applications
│   ├── traefik/                   # Traefik v3 via Helm + Gateway API CRDs
│   ├── cert-manager/              # cert-manager + ClusterIssuer + Certificate
│   ├── cloudnative-pg/            # CNPG operator + per-environment PG Cluster CRs
│   └── redis/                     # redis:7-alpine per environment
│
├── argocd/                        # Bootstrap (apply once, then GitOps takes over)
│   ├── app-of-apps.yaml           # Root Application — manages all other Applications
│   ├── infrastructure.yaml        # Points ArgoCD at the infrastructure/ directory
│   ├── staging.yaml               # Deploys app to staging namespace
│   └── production.yaml            # Deploys app to production namespace
│
├── .sops.yaml                     # SOPS encryption rules (age public key per env)
└── docs/
    ├── progress.md                # Full setup journal — recreate from scratch
    ├── learning-guide.md          # K8s concepts explained with real examples
    ├── operations-guide.md        # Day-2 ops: deployments, backups, debugging
    └── preview-environments-pattern.md
```

---

## Key Design Decisions

**App-of-apps pattern** — A single root ArgoCD Application manages all other Applications. Bootstrap the entire cluster with one `kubectl apply -f argocd/app-of-apps.yaml`.

**Kustomize over Helm for app manifests** — The app is simple enough that plain YAML with overlays is more readable and auditable than a Helm chart. Helm is reserved for third-party infra where charts are actively maintained upstream.

**SOPS + age over Sealed Secrets** — Secrets are encrypted at value level in Git. No in-cluster controller required for decryption, no dependency on a running CRD to read your own secrets.

**CloudNativePG over plain StatefulSet** — The CNPG operator handles PG lifecycle declaratively: initdb, credentials, streaming replication, connection pooling. S3 backup is configured directly in the Cluster CR.

**Gateway API over Ingress** — Traefik v3 implements the Gateway API standard (replacing the legacy Ingress resource). HTTPRoutes are more expressive and the API is now stable in Kubernetes.

**Separate deployments per component** — web, celery worker, and celery beat are three separate Deployments from the same image. Beat uses `Recreate` strategy to prevent duplicate scheduler instances.

---

## Environments

| | Staging | Production |
|-|---------|------------|
| URL | [staging.notafilia.es](https://staging.notafilia.es) | [notafilia.es](https://notafilia.es) |
| Namespace | `staging` | `production` |
| PostgreSQL | 1 instance, 10Gi | 1 instance, 20Gi |
| ArgoCD sync | Auto (prune + self-heal) | Self-heal only (manual prune) |

---

## Secrets Management

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and committed to Git. Each `secrets.enc.yaml` is a standard Kubernetes Secret manifest with values encrypted at the field level — keys are visible, values are ciphertext.

```bash
# Decrypt and edit interactively
sops overlays/staging/secrets.enc.yaml

# Re-encrypt after editing
sops -e -i overlays/staging/secrets.enc.yaml
```

The age private key is mounted into the ArgoCD repo-server as a K8s Secret, enabling decryption at sync time.

---

## Common Operations

```bash
# Validate manifests locally (no cluster needed)
kubectl kustomize overlays/staging
kubectl kustomize overlays/production

# Bootstrap the cluster (one-time)
kubectl apply -f argocd/app-of-apps.yaml

# Watch all ArgoCD apps
kubectl get applications -n argocd -w

# Tail production logs
kubectl logs -n production -l app.kubernetes.io/component=web -c web --tail=50 -f

# Run a Django management command
kubectl exec -n production deployment/notafilia-web -c web -- python manage.py shell

# Connect to PostgreSQL directly
kubectl port-forward -n production svc/notafilia-pg-rw 5434:5432
psql -h 127.0.0.1 -p 5434 -U notafilia -d notafilia
```

---

## Documentation

| Doc | What's in it |
|-----|-------------|
| [Setup Guide](docs/progress.md) | Complete step-by-step to recreate the infrastructure from zero |
| [Operations Guide](docs/operations-guide.md) | Day-2 ops: deploying, debugging, backups, scaling |
| [Learning Guide](docs/learning-guide.md) | K8s concepts explained using real examples from this project |
| [Preview Environments](docs/preview-environments-pattern.md) | Pattern for ephemeral per-PR environments |
| [Implementation Spec](docs/implementation-spec.md) | Original architecture planning document |
