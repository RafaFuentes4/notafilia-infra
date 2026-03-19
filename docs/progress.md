# Notafilia K8s Infrastructure — Progress Log

## Phase 1: Repository + Local Tooling (Complete)

### What was done
Created the `notafilia-infra` repository with the full GitOps structure for deploying Notafilia to Kubernetes.

### Repository structure created
```
notafilia-infra/
├── base/                          # Kustomize base — environment-agnostic app manifests
│   ├── kustomization.yaml         # Lists all resources, applies common labels
│   ├── deployment-web.yaml        # Gunicorn (1 replica, init container for migrations)
│   ├── deployment-celery.yaml     # Celery worker (--pool threads --concurrency 20)
│   ├── deployment-beat.yaml       # Celery beat (replicas: 1, strategy: Recreate)
│   ├── service-web.yaml           # ClusterIP on port 8000
│   ├── configmap.yaml             # DJANGO_SETTINGS_MODULE, ALLOWED_HOSTS, S3, email
│   └── httproute.yaml             # Gateway API route → notafilia-web:8000
├── overlays/
│   ├── staging/
│   │   ├── kustomization.yaml     # namespace: staging, host: staging.notafilia.com, tag: staging-latest
│   │   └── secrets.enc.yaml       # Placeholder secrets (to be encrypted with SOPS in Phase 4)
│   └── production/
│       ├── kustomization.yaml     # namespace: production, host: notafilia.com, tag: v1.0.0, 2 web replicas
│       └── secrets.enc.yaml       # Placeholder secrets
├── infrastructure/                # Third-party services managed by ArgoCD
│   ├── traefik/application.yaml   # Traefik v3 + Gateway API + LoadBalancer
│   ├── cert-manager/
│   │   ├── application.yaml       # cert-manager Helm chart
│   │   └── cluster-issuer.yaml    # Let's Encrypt ACME via Gateway API HTTP-01
│   ├── cloudnative-pg/
│   │   ├── application.yaml       # CloudNativePG operator (ServerSideApply for large CRDs)
│   │   ├── cluster-staging.yaml   # 1 PG instance, 10Gi, sync-wave: 1
│   │   └── cluster-production.yaml# 2 PG instances (HA), 20Gi, sync-wave: 1
│   └── redis/
│       ├── staging.yaml           # redis:7-alpine + PVC + Service (redis-master)
│       └── production.yaml        # Same for production namespace
├── argocd/                        # App-of-apps bootstrap
│   ├── app-of-apps.yaml           # Root Application → manages argocd/ directory
│   ├── infrastructure.yaml        # Scans infrastructure/ recursively, auto-prune
│   ├── staging.yaml               # Kustomize overlay for staging
│   └── production.yaml            # Kustomize overlay for production (prune: false for safety)
├── .sops.yaml                     # SOPS config with real age public key
├── .gitignore                     # Excludes kubeconfig files
├── README.md
└── docs/
    ├── implementation-spec.md     # Full spec with file contents and commands
    └── learning-guide.md          # Per-phase learning objectives and links
```

### Key design decisions
- **Kustomize for the app** (not Helm) — plain YAML with overlays is easier to read and debug than Go templates.
- **Helm only for third-party charts** — Traefik, cert-manager, CloudNativePG, Redis.
- **ArgoCD app-of-apps pattern** — one root Application bootstraps everything.
- **Init container for migrations** — runs `python manage.py migrate --noinput` before the web container starts. Failures are visible in ArgoCD UI.
- **Beat strategy: Recreate** — prevents duplicate scheduled tasks during rolling updates.
- **Gateway API instead of Ingress** — Ingress API is feature-frozen, ingress-nginx is EOL March 2026.
- **redis:7-alpine instead of Bitnami** — Bitnami ended free image distribution in Sep 2025.

### Issues encountered and resolved
1. **Kustomize `commonLabels` deprecated** — switched to the new `labels` syntax with `includeSelectors: true`.
2. **Redis only had staging Application** — added separate production Application.

---

## Phase 2: OVH Cluster Setup (Complete)

### What was done
Provisioned an OVH Managed Kubernetes cluster and configured all local tooling.

### Cluster details
| Setting | Value |
|---------|-------|
| Provider | OVH Public Cloud (Managed Kubernetes) |
| Region | Gravelines (GRA9), 1-AZ |
| Plan | Free |
| K8s version | 1.34.2 |
| Node pool | 1× B3-8 (8GB RAM, 2 vCPU, 50GB NVMe) |
| Billing | Hourly (~34€/month, covered by 200€ free trial credit) |
| Context name | `kubernetes-admin@notafilia` |

### CLI tools (all pre-installed)
- kubectl v1.32.7
- argocd v3.3.4
- helm v4.1.3
- sops 3.12.2
- age v1.3.1
- kustomize v5.8.1

### Configuration done
- **Kubeconfig** saved at `~/.kube/notafilia-ovh.yaml`, merged into `KUBECONFIG` env var in `~/.zshrc`.
- **Shell alias** `use-notafilia` added alongside existing `use-stg` / `use-prod` (Bettergy clusters).
- **Namespaces** created: `staging`, `production`.
- **Storage class** verified: `csi-cinder-high-speed` (default) — matches our CloudNativePG manifests.
- **Age keypair** generated at `~/.config/sops/age/keys.txt`, public key written to `.sops.yaml`, private key backed up in 1Password.

---

## Phase 3: ArgoCD + Infrastructure Services (Complete)

### What was done
Installed ArgoCD, deployed all infrastructure services via GitOps, and resolved bootstrapping issues.

### ArgoCD installation
- Installed via `kubectl apply` from the stable manifest.
- `applicationsets.argoproj.io` CRD required `--server-side --force-conflicts` due to annotation size limits.
- Admin password: retrieved via `argocd admin initial-password`.
- UI accessible via `kubectl port-forward svc/argocd-server -n argocd 8080:443`.

### SOPS integration
- Age private key stored as K8s Secret `age-key` in `argocd` namespace.
- ArgoCD `repo-server` patched to mount the key at `/home/argocd/.config/sops/age/` with `SOPS_AGE_KEY_FILE` env var.
- **Note:** Full SOPS decryption (kustomize-sops plugin) deferred to Phase 4. For now, staging/production apps use plain Kustomize.

### Gateway API CRDs
- Installed v1.4.0 standard CRDs (`kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml`).

### Infrastructure services deployed

| Service | Status | Details |
|---------|--------|---------|
| **Traefik** | Running | Pod healthy, LoadBalancer IP: **57.128.58.136**, Gateway API enabled |
| **cert-manager** | Healthy | 3 pods (controller, cainjector, webhook), CRDs installed |
| **ClusterIssuer** | Synced | `letsencrypt-prod` with HTTP-01 solver via Gateway API |
| **CloudNativePG operator** | Healthy | CRDs installed (ServerSideApply enabled for large CRDs) |
| **PostgreSQL (staging)** | Bootstrapping | 1 instance, 10Gi storage, database `notafilia` |
| **PostgreSQL (production)** | Bootstrapping | 2 instances (HA), 20Gi storage, database `notafilia` |
| **Redis (staging)** | Running | redis:7-alpine, 2Gi PVC, service: `redis-master` |
| **Redis (production)** | Running | redis:7-alpine, 2Gi PVC, service: `redis-master` |

### Current ArgoCD application status
All 7 Applications are **Synced**:
- `notafilia-root` — Healthy
- `cert-manager` — Healthy
- `cloudnative-pg-operator` — Healthy
- `notafilia-infrastructure` — Progressing (PG clusters bootstrapping)
- `traefik` — Degraded (Gateway not fully programmed until TLS cert exists)
- `notafilia-staging` — Degraded (no Docker image built yet — expected)
- `notafilia-production` — Degraded (no Docker image built yet — expected)

### Issues encountered and resolved
1. **CRD ordering (chicken-and-egg)** — CloudNativePG Cluster CRs and ClusterIssuer depend on CRDs installed by operators. Fixed with `argocd.argoproj.io/sync-wave: "1"` annotations and `SkipDryRunOnMissingResource=true`.
2. **Bitnami Redis images gone (Broadcom ended free images Sep 2025)** — Replaced Bitnami Helm chart with plain manifests using official `redis:7-alpine`. Updated `REDIS_URL` in secrets to match new service name.
3. **CloudNativePG `poolers` CRD too large for client-side apply** — Applied with `--server-side --force-conflicts`, then enabled `ServerSideApply=true` in the operator's ArgoCD Application.
4. **Traefik chart v34 schema change** — `gateway.listeners` changed from array to map format. Fixed values to use `web`/`websecure` named keys with Traefik internal ports (8000/8443).
5. **`ServerSideApply` conflicting with `--force` in retry loops** — Removed `ServerSideApply` from the infrastructure Application. `SkipDryRunOnMissingResource` handles CRD ordering alone.
6. **`kustomize-sops` plugin never installed** — Staging/production apps referenced a CMP plugin that didn't exist, causing "Unknown" sync status. Removed plugin reference for now; SOPS decryption will be configured in Phase 4.
7. **Orphaned Bitnami Redis PVCs** — Deleted `redis-data-redis-staging-master-0` and `redis-data-redis-production-master-0`.

---

## What's Next

### Phase 4: App Deployment (Staging)
- Encrypt secrets with SOPS (real values for staging)
- Build and push Docker image to GHCR
- Verify staging deployment works end-to-end

### Phase 5: CI/CD (GitHub Actions)
- Add workflow to notafilia app repo: build on push to main → push to GHCR
- Configure automatic staging updates
- Manual production promotion flow

### Phase 6: Production
- Encrypt production secrets
- Configure DNS (notafilia.com → 57.128.58.136)
- Verify TLS certificate provisioning
