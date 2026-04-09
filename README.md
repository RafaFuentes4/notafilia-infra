# notafilia-infra

Kubernetes infrastructure for [Notafilia](https://github.com/RafaFuentes4/notafilia), a Django application running in production on OVH Managed Kubernetes. Built around GitOps principles — the cluster state is fully declarative and driven by this repository.

**Production** → [notafilia.es](https://notafilia.es) &nbsp;|&nbsp; **Staging** → [staging.notafilia.es](https://staging.notafilia.es)

---

## What this repo does

This repository is the single source of truth for the entire infrastructure. ArgoCD watches it and reconciles the cluster automatically — no manual `kubectl apply`, no configuration drift.

Everything is here: app deployments, ingress routing, TLS certificates, PostgreSQL clusters, Redis, secrets, and automated backups.

---

## Stack

| Concern | Tool | Why |
|---------|------|-----|
| GitOps controller | **ArgoCD** | App-of-apps pattern, self-healing, drift detection |
| App manifests | **Kustomize** | Plain YAML with environment overlays — no templating engine needed |
| Ingress | **Traefik v3 + Gateway API** | Modern routing standard, replaces Ingress resource |
| TLS | **cert-manager + Let's Encrypt** | Fully automated certificate lifecycle |
| Secrets | **SOPS + age** | Encrypted at value-level in Git — safe to commit, no secrets controller needed |
| PostgreSQL | **CloudNativePG operator** | Production-grade PG on K8s with streaming replication support |
| Async tasks | **Celery + Redis** | Worker and beat scheduler as separate deployments |
| Media storage | **OVH Object Storage (S3-compatible)** | Offloaded from pods via django-storages |
| DB backups | **Barman → OVH S3** | Daily scheduled backups with 2-day retention |
| CI/CD | **GitHub Actions → GHCR** | Image built and pushed on merge to main |
| Cluster | **OVH Managed Kubernetes** (GRA9, B3-8 node) | Managed control plane, OVH Cinder persistent volumes |

---

## Architecture

```
Internet
  └─▶ DNS (notafilia.es / staging.notafilia.es)
        └─▶ OVH LoadBalancer (public IP)
              └─▶ Traefik (TLS termination, Let's Encrypt cert)
                    └─▶ Gateway API HTTPRoute (host-based routing)
                          └─▶ notafilia-web Service
                                └─▶ Gunicorn pod
                                      ├─▶ CloudNativePG (PostgreSQL)
                                      ├─▶ Redis (session/cache/broker)
                                      └─▶ OVH Object Storage (media files)

GitOps loop:
  Git push → ArgoCD detects diff → reconciles cluster state
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
├── infrastructure/                # Third-party services managed as ArgoCD Applications
│   ├── traefik/                   # Traefik v3 via Helm + Gateway API CRDs
│   ├── cert-manager/              # cert-manager + ClusterIssuer + Certificate
│   ├── cloudnative-pg/            # CNPG operator + per-environment PG Cluster CRs
│   └── redis/                     # redis:7-alpine StatefulSet per environment
│
├── argocd/                        # ArgoCD bootstrap (apply once, then GitOps takes over)
│   ├── app-of-apps.yaml           # Root Application — manages all other Applications
│   ├── infrastructure.yaml        # Points ArgoCD at the infrastructure/ directory
│   ├── staging.yaml               # Deploys app to staging namespace
│   └── production.yaml            # Deploys app to production namespace
│
├── .sops.yaml                     # SOPS encryption rules (age public key per env)
└── docs/
    ├── progress.md                # Full setup journal — recreate from scratch
    ├── learning-guide.md          # K8s concepts explained with examples from this project
    ├── operations-guide.md        # Day-2 operations: deployments, backups, debugging
    └── preview-environments-pattern.md  # Pattern for ephemeral preview environments
```

---

## Key Design Decisions

**App-of-apps pattern** — A single root ArgoCD Application manages all other Applications. Bootstrap the entire cluster with one `kubectl apply`.

**Kustomize over Helm for app manifests** — The app is simple enough that plain YAML with overlays is more readable and auditable than a Helm chart. Helm is reserved for third-party infra (Traefik, cert-manager) where charts are maintained upstream.

**SOPS + age over Sealed Secrets** — Secrets are encrypted at value level in Git. No in-cluster controller required for decryption, no dependency on a running CRD to read your own secrets. The age private key lives only in the cluster (as a K8s Secret) and in a secure backup.

**CloudNativePG over plain StatefulSet** — The CNPG operator handles PG lifecycle (initdb, credentials, streaming replication, connection pooling) declaratively. Backup to S3-compatible storage is configured in the Cluster CR.

**Gateway API over Ingress** — Traefik v3 supports the Gateway API standard (replacing the legacy Ingress resource). HTTPRoute resources are more expressive and the API is now stable in Kubernetes.

**Separate deployments per component** — web, celery worker, and celery beat are three separate Deployments from the same image. Beat uses `Recreate` strategy to prevent duplicate scheduler instances.

---

## App Components

Three deployments, one image (`ghcr.io/rafafuentes4/notafilia`):

| Deployment | Command | Notes |
|------------|---------|-------|
| `notafilia-web` | `gunicorn --bind 0.0.0.0:8000 --workers 1 --threads 8` | Django migrate runs as init container |
| `notafilia-celery` | `celery -A notafilia worker --pool threads --concurrency 20` | Async task processing |
| `notafilia-beat` | `celery -A notafilia beat -l INFO` | Periodic task scheduler, Recreate strategy |

---

## Environments

| | Staging | Production |
|-|---------|------------|
| URL | [staging.notafilia.es](https://staging.notafilia.es) | [notafilia.es](https://notafilia.es) |
| Namespace | `staging` | `production` |
| PostgreSQL | 1 instance, 10Gi | 1 instance, 20Gi |
| Replicas (web) | 1 | 1 |
| ArgoCD sync | Auto (prune + self-heal) | Self-heal only (no auto-prune) |

---

## Secrets Management

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and committed to Git. Each `secrets.enc.yaml` is a standard Kubernetes Secret manifest encrypted at value level — the keys are visible, only the values are ciphertext.

```bash
# Decrypt and edit a secret
sops overlays/staging/secrets.enc.yaml

# Re-encrypt after editing
sops -e -i overlays/staging/secrets.enc.yaml
```

The age private key is stored as a K8s Secret in the cluster and mounted into the ArgoCD repo-server for decryption at sync time.

---

## Automated Backups

PostgreSQL production backups run daily via CloudNativePG's Barman integration, writing to OVH Object Storage (S3-compatible):

```
s3://notafilia-media/pg-backups/production
```

Retention: 2 days. Restore procedure documented in [ops guide](docs/operations-guide.md).

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

# Tail app logs
kubectl logs -n production -l app.kubernetes.io/component=web -c web --tail=50 -f

# Run a Django management command
kubectl exec -n production deployment/notafilia-web -c web -- python manage.py shell

# Connect to PostgreSQL directly
kubectl port-forward -n production svc/notafilia-pg-rw 5434:5432
psql -h 127.0.0.1 -p 5434 -U notafilia -d notafilia

# Decrypt and inspect secrets
sops -d overlays/staging/secrets.enc.yaml
```

---

## Deploy a New Version

Image tags are pinned in `overlays/*/kustomization.yaml`. To deploy:

```bash
# Update the image tag in both overlays
NEW_TAG=0.6.0
sed -i '' "s/newTag: .*/newTag: $NEW_TAG/" overlays/staging/kustomization.yaml
git commit -am "chore: update image tag to $NEW_TAG in staging"
git push
# ArgoCD picks up the change and rolls out automatically
```

Full deployment guide in [docs/operations-guide.md](docs/operations-guide.md).

---

## Documentation

| Doc | What's in it |
|-----|-------------|
| [Setup Guide](docs/progress.md) | Complete step-by-step to recreate the infrastructure from zero |
| [Operations Guide](docs/operations-guide.md) | Day-2 ops: deploying, debugging, backups, scaling |
| [Learning Guide](docs/learning-guide.md) | K8s concepts explained using real examples from this project |
| [Preview Environments](docs/preview-environments-pattern.md) | Pattern for ephemeral per-PR environments |
| [Implementation Spec](docs/implementation-spec.md) | Original architecture planning document |
