# Notafilia K8s Infrastructure — Complete Setup Guide

This guide documents every step to deploy the Notafilia Django application to Kubernetes on OVH from scratch. It includes the exact commands, configuration files, pitfalls encountered, and their solutions.

**Final state**: Django app (web + celery + celery beat) running on OVH Managed Kubernetes with HTTPS, PostgreSQL (CloudNativePG), Redis, Traefik Gateway API routing, cert-manager TLS, and ArgoCD GitOps — across staging and production environments.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Phase 1: Repository Setup](#2-phase-1-repository-setup)
3. [Phase 2: OVH Cluster](#3-phase-2-ovh-cluster)
4. [Phase 3: ArgoCD + Infrastructure](#4-phase-3-argocd--infrastructure)
5. [Phase 4: App Deployment](#5-phase-4-app-deployment)
6. [Phase 5: TLS/HTTPS](#6-phase-5-tlshttps)
7. [Phase 6: CI/CD](#7-phase-6-cicd)
8. [Phase 7: DNS](#8-phase-7-dns)
9. [Post-Deployment Tasks](#9-post-deployment-tasks)
10. [Final Architecture](#10-final-architecture)
11. [Gotchas & Lessons Learned](#11-gotchas--lessons-learned)
12. [Troubleshooting](#12-troubleshooting)
13. [Common Operations](#13-common-operations)

---

## 1. Prerequisites

### Tools (macOS)

```bash
brew install kubectl argocd helm sops age kustomize
```

Verified versions:
- kubectl v1.32.7
- argocd v3.3.4
- helm v4.1.3
- sops 3.12.2
- age v1.3.1
- kustomize v5.8.1

### Accounts
- **OVH Public Cloud** with billing configured
- **GitHub** account with repos: `notafilia` (app) and `notafilia-infra` (infrastructure)
- **Domain registrar** for DNS (we use GoDaddy for `notafilia.es`)

### Technology Stack

| Layer | Tool | Why |
|-------|------|-----|
| GitOps | ArgoCD | Visual UI, 60% market share, great for learning |
| App manifests | Kustomize | Plain YAML + overlays, no Go templates |
| Infrastructure | Helm | For third-party charts only |
| Ingress | Traefik + Gateway API | ingress-nginx EOL March 2026 |
| TLS | cert-manager + Let's Encrypt | ACME HTTP-01 via Gateway API |
| Secrets | SOPS + age | Value-level encryption, no controller needed |
| PostgreSQL | CloudNativePG | Purpose-built operator, automated failover |
| Redis | Official redis:7-alpine | Bitnami images no longer free (Sep 2025) |
| CI/CD | GitHub Actions → GHCR | Native OIDC auth, free for public repos |
| Cluster | OVH Managed K8s | Free control plane, pay only for nodes |

---

## 2. Phase 1: Repository Setup

### 2.1 Create the repo

```bash
cd ~/Developer
mkdir notafilia-infra && cd notafilia-infra
git init
gh repo create RafaFuentes4/notafilia-infra --private --source=. --push
```

### 2.2 Directory structure

```bash
mkdir -p base
mkdir -p overlays/staging overlays/production
mkdir -p infrastructure/traefik infrastructure/cert-manager
mkdir -p infrastructure/cloudnative-pg infrastructure/redis
mkdir -p argocd docs
```

### 2.3 Repository layout (final)

```
notafilia-infra/
├── base/                              # Kustomize base (environment-agnostic)
│   ├── kustomization.yaml             # Resource list + labels
│   ├── deployment-web.yaml            # Gunicorn + migrate init container
│   ├── deployment-celery.yaml         # Celery worker
│   ├── deployment-beat.yaml           # Celery beat (Recreate strategy)
│   ├── service-web.yaml               # ClusterIP:8000
│   ├── configmap.yaml                 # Non-secret env vars
│   └── httproute.yaml                 # Gateway API route
├── overlays/
│   ├── staging/
│   │   ├── kustomization.yaml         # Patches for staging
│   │   └── secrets.enc.yaml           # SOPS-encrypted secrets
│   └── production/
│       ├── kustomization.yaml         # Patches for production
│       └── secrets.enc.yaml           # SOPS-encrypted secrets
├── infrastructure/                    # Third-party services (ArgoCD managed)
│   ├── traefik/application.yaml       # Traefik Helm chart (34.*)
│   ├── cert-manager/
│   │   ├── application.yaml           # cert-manager Helm chart (v1.*)
│   │   ├── cluster-issuer.yaml        # Let's Encrypt ACME issuer
│   │   └── certificate.yaml           # TLS cert for both domains
│   ├── cloudnative-pg/
│   │   ├── application.yaml           # CNPG operator (pinned 0.25.0)
│   │   ├── cluster-staging.yaml       # 1 PG instance, 10Gi
│   │   └── cluster-production.yaml    # 1 PG instance, 20Gi
│   └── redis/
│       ├── staging.yaml               # redis:7-alpine + PVC + Service
│       └── production.yaml            # Same for production
├── argocd/                            # App-of-apps bootstrap
│   ├── app-of-apps.yaml               # Root Application
│   ├── infrastructure.yaml            # Infrastructure Application
│   ├── staging.yaml                   # Staging Application
│   └── production.yaml                # Production Application
├── .sops.yaml                         # SOPS encryption config
├── .gitignore                         # Excludes kubeconfig files
└── README.md
```

### 2.4 Key design decisions

- **Kustomize for the app** — overlays patch base YAML per environment. No Go templates.
- **Helm only for third-party charts** — Traefik, cert-manager, CloudNativePG operator.
- **ArgoCD app-of-apps** — one root Application bootstraps everything from Git.
- **Init container for migrations** — `manage.py migrate` runs before Gunicorn starts.
- **Beat strategy: Recreate** — prevents duplicate scheduled tasks during deployments.
- **`/up` for health probes** (not `/health/`) — `/up` uses Django middleware that bypasses `ALLOWED_HOSTS` validation. `/health/` gets blocked when accessed via pod IP.
- **GHCR package is public** — no `imagePullSecrets` needed. If the package were ever made private again, you would need to add them.
- **redis:7-alpine instead of Bitnami** — Broadcom ended free Bitnami images in Sep 2025.
- **Gateway `namespacePolicy: All`** — allows HTTPRoutes in staging/production to reference the Gateway in the traefik namespace.
- **Pin CNPG operator version** — wildcard versions cause auto-upgrade bootstrap loops.
- **Sync-wave annotations** — CRD-dependent resources (ClusterIssuer, PG Clusters) use `sync-wave: "1"` so operators install first.

### 2.5 Validate locally

```bash
kubectl kustomize base/                  # Should render valid YAML
kubectl kustomize overlays/staging/      # Should show staging patches
kubectl kustomize overlays/production/   # Should show production patches
```

---

## 3. Phase 2: OVH Cluster

### 3.1 Create the cluster

OVH Manager → Public Cloud → Managed Kubernetes → Create:

| Setting | Value |
|---------|-------|
| Name | `notafilia` |
| Region | Gravelines (GRA9), 1-AZ |
| Plan | Free |
| K8s version | Latest stable (1.34) |
| Security policy | Maximum security |
| Private network | None (public IPs) |
| Node pool flavor | B3-8 (8GB RAM, 2 vCPU, 50GB NVMe) |
| **Node count** | **2** |
| Auto-scaling | Off |
| Billing | Hourly (~68€/month for 2 nodes) |
| Pool name | `general` |

> **Critical: Use 2 nodes minimum.** A single B3-8 doesn't have enough CPU for all infrastructure + app pods. We initially tried 1 node and hit `Insufficient cpu` scheduling failures.

Wait ~5-10 minutes for provisioning.

### 3.2 Configure kubectl

```bash
# Download kubeconfig from OVH Manager → cluster → "Download kubeconfig"
mv ~/Downloads/kubeconfig-*.yml ~/.kube/notafilia-ovh.yaml

# Add to ~/.zshrc
export KUBECONFIG="$HOME/.kube/notafilia-ovh.yaml"
# (or append with colon if you have other clusters)

# Convenience alias
alias use-notafilia='kubectl config use-context kubernetes-admin@notafilia'

# Verify
source ~/.zshrc
use-notafilia
kubectl get nodes  # Should show 2 Ready nodes
```

### 3.3 Create namespaces

```bash
kubectl create namespace staging
kubectl create namespace production
```

### 3.4 Verify storage class

```bash
kubectl get storageclass
# csi-cinder-high-speed (default) — this is what PG and Redis manifests use
```

### 3.5 Generate SOPS encryption keys

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Output: Public key: age1xxxxxx...

# BACK UP the private key to 1Password (or other password manager)
cat ~/.config/sops/age/keys.txt
```

Update `.sops.yaml` with your actual public key, commit, and push.

---

## 4. Phase 3: ArgoCD + Infrastructure

### 4.1 Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# If "annotations too long" error on CRDs:
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts

# Wait for pods
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s

# Get admin password
argocd admin initial-password -n argocd

# Access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080 → login admin + password
```

### 4.2 Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### 4.3 Mount SOPS age key in ArgoCD

```bash
# Create secret
kubectl create secret generic age-key \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt \
  -n argocd

# Patch repo-server
kubectl patch deployment argocd-repo-server -n argocd --type json -p '[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {"name": "age-key", "secret": {"secretName": "age-key"}}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {"name": "age-key", "mountPath": "/home/argocd/.config/sops/age"}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {"name": "SOPS_AGE_KEY_FILE", "value": "/home/argocd/.config/sops/age/keys.txt"}
  }
]'

kubectl rollout status deployment argocd-repo-server -n argocd --timeout=120s
```

### 4.4 Deploy the app-of-apps

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

This single command bootstraps everything:
1. ArgoCD reads `argocd/` → creates child Applications
2. `notafilia-infrastructure` scans `infrastructure/` → deploys Traefik, cert-manager, CNPG, Redis
3. `notafilia-staging` and `notafilia-production` deploy app overlays

---

## 5. Phase 4: App Deployment

### 5.1 Build and push Docker image

> **Note**: This is now fully automated via CI/CD:
> - **Push to `main`** → CI builds image → dispatches to infra repo → staging auto-updates (no manual step needed)
> - **Version tag `v*`** → CI builds image → dispatches to infra repo → BOTH staging + production auto-update
> - ArgoCD polling interval is 30 seconds
>
> The manual steps below are only needed for initial setup or if CI is unavailable.

> **Critical**: Build for `linux/amd64` — OVH nodes are x86_64, your Mac is ARM. Building without `--platform` gives `exec format error`.

```bash
cd ~/Developer/notafilia

# Ensure GHCR write access
gh auth refresh -h github.com -s write:packages,read:packages
gh auth token | docker login ghcr.io -u <github-username> --password-stdin

# Build and push for amd64
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/rafafuentes4/notafilia:staging-latest \
  --push .

# Also tag for production
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/rafafuentes4/notafilia:v1.0.0 \
  --push .
```

### 5.2 Configure GHCR package permissions

Go to: **https://github.com/users/RafaFuentes4/packages/container/notafilia/settings**

Under **Manage Actions access** → Add Repository → `notafilia` → Role: **Write**

### 5.3 imagePullSecret (not needed)

**GHCR is public.** No imagePullSecret needed. If the package were ever made private again, you would need to create imagePullSecrets in both namespaces.

### 5.4 Create app secrets

Get CloudNativePG auto-generated passwords:

```bash
kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d
kubectl get secret notafilia-pg-app -n production -o jsonpath='{.data.password}' | base64 -d
```

Generate a Django SECRET_KEY:

```bash
python3 -c "from secrets import token_urlsafe; print(token_urlsafe(50))"
```

Create secrets (replace `<placeholders>`):

```bash
kubectl apply -n staging -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: notafilia-secrets
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
    argocd.argoproj.io/sync-options: Prune=false
type: Opaque
stringData:
  SECRET_KEY: "<generated-key>"
  DATABASE_URL: "postgresql://notafilia:<staging-pg-password>@notafilia-pg-rw.staging:5432/notafilia"
  REDIS_URL: "redis://redis-master.staging:6379/0"
  AWS_ACCESS_KEY_ID: ""
  AWS_SECRET_ACCESS_KEY: ""
  SENTRY_DSN: ""
  TURNSTILE_KEY: ""
  TURNSTILE_SECRET: ""
  ANTHROPIC_API_KEY: ""
  DEFAULT_AI_MODEL: "claude-sonnet-4-6"
  OPENAI_API_KEY: ""
EOF
```

Repeat for production with production PG password and `redis-master.production`.

> **Important**: The `argocd.argoproj.io/compare-options: IgnoreExtraneous` annotation prevents ArgoCD from pruning this secret (since it's not in the Kustomize resources).

### 5.5 Restart deployments

```bash
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n staging
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n production
```

### 5.6 Verify

```bash
kubectl get pods -n staging       # All 5 pods Running 1/1
kubectl get pods -n production    # All 5 pods Running 1/1
curl -s http://staging.notafilia.es/up   # Should return "OK"
```

---

## 6. Phase 5: TLS/HTTPS

### 6.1 How it works

cert-manager watches the `Certificate` resource, contacts Let's Encrypt, performs HTTP-01 challenges via Gateway API HTTPRoutes, and stores the certificate as a Kubernetes Secret. Traefik references this Secret in its Gateway listener.

### 6.2 Configuration

The following files handle TLS (already in the repo):

- `infrastructure/cert-manager/application.yaml` — cert-manager with Gateway API enabled (`featureGates: ExperimentalGatewayAPISupport=true` + `extraArgs: [--enable-gateway-api]`)
- `infrastructure/cert-manager/cluster-issuer.yaml` — Let's Encrypt ACME issuer using Gateway API HTTP-01 solver
- `infrastructure/cert-manager/certificate.yaml` — Certificate resource for both `notafilia.es` and `staging.notafilia.es`

### 6.3 Gotcha: cert-manager needs restart after config change

After enabling Gateway API support, cert-manager pods must be restarted:

```bash
kubectl rollout restart deployment cert-manager -n cert-manager
```

Then delete and recreate any stuck challenges:

```bash
kubectl delete challenges --all -n traefik
kubectl delete certificate notafilia-tls -n traefik
# ArgoCD recreates the Certificate automatically
```

### 6.4 Verify

```bash
kubectl get certificate -n traefik
# READY should be True

curl -sk https://staging.notafilia.es/up
# Should return "OK"
```

---

## 7. Phase 6: CI/CD

### 7.1 GitHub Actions workflow (fully automated)

File: `notafilia/.github/workflows/build-and-push.yml` (in the **app** repo, not infra)

The pipeline is fully automated via `repository_dispatch` to the infra repo:

- **Push to `main`** → CI builds image → dispatches to infra repo → staging overlay auto-updated → ArgoCD syncs within 30 seconds
- **Version tag `v*`** → CI builds image → dispatches to infra repo → BOTH staging + production overlays auto-updated → ArgoCD syncs within 30 seconds

On every push to `main`:
1. Builds `linux/amd64` Docker image from `Dockerfile.web`
2. Pushes to GHCR with tags: `${{ github.sha }}` + `staging-latest`
3. Uses GitHub Actions cache for fast builds
4. Dispatches `repository_dispatch` to `notafilia-infra` to update image tags

On version tags (`v*`):
1. Same build + push steps
2. Dispatches to infra repo, which updates both staging and production overlays

No manual `kubectl rollout restart` or image tagging is needed.

### 7.2 GHCR package permissions

The workflow uses `${{ secrets.GITHUB_TOKEN }}` (automatic OIDC). But the GHCR package must have the repo linked:

**https://github.com/users/RafaFuentes4/packages/container/notafilia/settings**
→ Manage Actions access → Add `notafilia` repo with **Write** role

### 7.3 Production promotion

Production promotion is automated: push a `v*` tag to the app repo and CI handles everything.

```bash
# Create a version tag — CI does the rest
git tag v1.1.0
git push origin v1.1.0
# CI builds → dispatches to infra repo → staging + production auto-update
```

Manual promotion (if CI is unavailable):

```bash
# Tag the staging image
docker pull ghcr.io/rafafuentes4/notafilia:staging-latest
docker tag ghcr.io/rafafuentes4/notafilia:staging-latest ghcr.io/rafafuentes4/notafilia:v1.1.0
docker push ghcr.io/rafafuentes4/notafilia:v1.1.0

# Update production overlay
cd notafilia-infra/overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:v1.1.0
git commit -am "Promote v1.1.0 to production" && git push
```

---

## 8. Phase 7: DNS

### 8.1 Get Traefik external IP

```bash
kubectl get svc -n traefik
# EXTERNAL-IP: 57.128.58.136
```

### 8.2 Add DNS records

In your domain registrar:

| Type | Name | Value | TTL | Note |
|------|------|-------|-----|------|
| A | `@` | `57.128.58.136` | 600 | Production |
| A | `staging` | `57.128.58.136` | 600 | Staging |
| A | `*` | `57.128.58.136` | 600 | Wildcard for preview environments |

### 8.3 Verify

```bash
dig +short notafilia.es           # Should return the IP
dig +short staging.notafilia.es   # Should return the IP
curl -s https://staging.notafilia.es/up   # HTTP 200 OK
curl -s https://notafilia.es/up           # HTTP 200 OK
```

### 8.4 Important: Restart web pods after DNS/domain changes

If you change `ALLOWED_HOSTS` in the ConfigMap, pods must be restarted to pick up the new value:

```bash
kubectl rollout restart deployment notafilia-web -n staging
kubectl rollout restart deployment notafilia-web -n production
```

---

## 9. Post-Deployment Tasks

### 9.1 Create a superuser

First sign up via the web UI, then promote:

```bash
# Staging
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py promote_user_to_superuser rafafcantero@gmail.com

# Production
kubectl exec -n production deployment/notafilia-web -c web -- \
  python manage.py promote_user_to_superuser rafafcantero@gmail.com
```

Admin panel: `https://staging.notafilia.es/admin/`

### 9.2 Configure PostgreSQL backups (production only)

Automated daily backups are configured via CloudNativePG. The setup requires:

1. **Create backup credentials** in the production namespace:

```bash
kubectl create secret generic pg-backup-creds -n production \
  --from-literal=ACCESS_KEY_ID=<your-ovh-s3-access-key> \
  --from-literal=SECRET_ACCESS_KEY=<your-ovh-s3-secret-key>
```

2. **Backup config is in Git** — ArgoCD deploys it automatically:
   - `infrastructure/cloudnative-pg/cluster-production.yaml` — backup section pointing to `s3://notafilia-media/pg-backups/production/`
   - `infrastructure/cloudnative-pg/scheduled-backup-production.yaml` — daily schedule at 2:00 AM UTC, retain 2 days

3. **Verify backups are running:**

```bash
kubectl get backups -n production
kubectl get scheduledbackups -n production
```

4. **Trigger a manual test backup:**

```bash
kubectl apply -n production -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-test
  namespace: production
spec:
  method: barmanObjectStore
  cluster:
    name: notafilia-pg
EOF
# Should show PHASE: completed within ~30 seconds
kubectl get backups -n production
```

### 9.3 Run any management command

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py <command> [args]
```

### 9.3 View logs

```bash
# Web (Gunicorn)
kubectl logs -n staging -l app.kubernetes.io/component=web -c web --tail=50

# Migrations (init container)
kubectl logs -n staging -l app.kubernetes.io/component=web -c migrate --tail=50

# Celery worker
kubectl logs -n staging -l app.kubernetes.io/component=celery --tail=50

# Celery beat
kubectl logs -n staging -l app.kubernetes.io/component=beat --tail=50

# PostgreSQL
kubectl logs -n staging notafilia-pg-1 --tail=50
```

---

## 10. Final Architecture

### Cluster topology

```
OVH Managed K8s (GRA9, K8s 1.34.2)
├── 2× B3-8 nodes (8GB RAM, 2 vCPU each)
│
├── argocd namespace (7 pods)
│   └── server, repo-server, app-controller, redis, dex, notifications, applicationset
│
├── cert-manager namespace (3 pods)
│   └── controller (Gateway API enabled), cainjector, webhook
│
├── cnpg-system namespace (1 pod)
│   └── CloudNativePG operator (pinned 0.25.0)
│
├── traefik namespace (1 pod)
│   └── Traefik proxy (LoadBalancer: 57.128.58.136)
│   └── TLS cert: notafilia-tls (Let's Encrypt, auto-renewed)
│
├── staging namespace (5 pods)
│   ├── notafilia-web (Gunicorn, 1 replica, init: migrate)
│   ├── notafilia-celery (worker, 1 replica)
│   ├── notafilia-beat (scheduler, 1 replica, Recreate)
│   ├── notafilia-pg-1 (PostgreSQL 18, 10Gi, CloudNativePG)
│   └── redis (7-alpine, 2Gi PVC)
│
└── production namespace (5 pods)
    ├── notafilia-web (Gunicorn, 1 replica, init: migrate)
    ├── notafilia-celery (worker, 1 replica)
    ├── notafilia-beat (scheduler, 1 replica, Recreate)
    ├── notafilia-pg-1 (PostgreSQL 18, 20Gi, CloudNativePG)
    └── redis (7-alpine, 2Gi PVC)
```

### ArgoCD Applications (all Synced + Healthy)

| Application | Source | What it deploys |
|-------------|--------|-----------------|
| notafilia-root | `argocd/` | All other Applications |
| notafilia-infrastructure | `infrastructure/` (recursive) | Traefik, cert-manager, CNPG, Redis, PG clusters |
| cert-manager | Helm: charts.jetstack.io | cert-manager controller + CRDs |
| cloudnative-pg-operator | Helm: cloudnative-pg.github.io | CNPG operator + CRDs |
| traefik | Helm: traefik.github.io | Traefik proxy + Gateway |
| notafilia-staging | `overlays/staging` | App deployments in staging |
| notafilia-production | `overlays/production` | App deployments in production |

### Networking flow

```
Internet → DNS (notafilia.es / staging.notafilia.es)
  → OVH LoadBalancer (57.128.58.136:443)
    → Traefik pod (TLS termination via cert-manager cert)
      → Gateway API HTTPRoute (host-based routing)
        → notafilia-web Service (ClusterIP:8000)
          → Gunicorn pod
```

### Monthly cost
- 2× B3-8 nodes: ~68€/month (covered by 200€ OVH free trial credit)
- Cluster control plane: Free
- LoadBalancer: Included
- Block storage (~36Gi total PVCs): ~5€/month

---

## What's working

- Django app (web + celery + celery beat) deployed across staging and production
- PostgreSQL (CloudNativePG) with per-environment instances
- Redis (official redis:7-alpine) with persistent storage
- Traefik Gateway API routing with host-based routing
- TLS/HTTPS via cert-manager + Let's Encrypt (auto-renewed)
- HTTP-to-HTTPS redirect (301 permanent via Traefik)
- ArgoCD GitOps with app-of-apps pattern
- SOPS + age encrypted secrets
- Init container migrations (run before Gunicorn starts)
- S3 media storage (OVH Object Storage, bucket: notafilia-media, region: GRA)
- Automated CI/CD (push to main auto-deploys staging, version tags deploy both staging + production)
- Preview environments (scripts in `scripts/`)
- Wildcard DNS (`*.notafilia.es`)
- PostgreSQL automated daily backups to S3 (production, retain 2 days)

## What's not yet done

- SOPS decryption in ArgoCD (age key is mounted, but encrypted secrets are not yet used in overlays)
- ArgoCD notifications (Slack/email alerts on sync failures)

---

## 11. Gotchas & Lessons Learned

These are the issues we hit during setup, in order. If you're recreating this from scratch using the final manifests, you should avoid most of them — but knowing about them helps if something goes wrong.

### Build & Deploy

1. **Always build for `linux/amd64`**: Use `docker buildx build --platform linux/amd64`. Without this, ARM images cause `exec format error` on x86 nodes.

2. **GHCR packages are private by default** (now public): The package is now public, so imagePullSecrets are no longer needed. If it were ever made private again, pods would get `ImagePullBackOff` with 403 — fix by creating `ghcr-credentials` imagePullSecret in each namespace AND linking the package to the repo in GHCR settings.

3. **GHCR Actions permissions**: The CI/CD workflow's `${{ secrets.GITHUB_TOKEN }}` gets 403 unless you add the repo to the package's "Manage Actions access" with Write role.

### Kubernetes & Kustomize

4. **Use `labels` not `commonLabels`** in kustomization.yaml — `commonLabels` is deprecated.

5. **Health probes must use `/up`** (not `/health/`): Django's `ALLOWED_HOSTS` blocks requests to pod IPs. The `/up` middleware-based endpoint bypasses this.

6. **`ALLOWED_HOSTS` changes require pod restart**: ConfigMap changes don't auto-restart pods. Run `kubectl rollout restart deployment notafilia-web`.

7. **2 nodes minimum for B3-8**: A single node can't fit all infrastructure + app pods. CPU scheduling fails.

### ArgoCD

8. **CRD ordering with sync-waves**: Resources like PG Clusters and ClusterIssuers need `sync-wave: "1"` annotations. Their operators (wave 0) must install first. Also use `SkipDryRunOnMissingResource=true` on the infrastructure Application.

9. **Don't combine `ServerSideApply` with `--force` in retry loops**: They conflict. Use `SkipDryRunOnMissingResource` alone on the infrastructure Application.

10. **Secrets managed outside Kustomize get pruned**: If a Secret isn't in Kustomize resources but ArgoCD manages the namespace, it gets deleted on sync. Fix: annotate with `argocd.argoproj.io/compare-options: IgnoreExtraneous`.

### Infrastructure

11. **Bitnami images are gone**: Broadcom ended free distribution (Sep 2025). Use official images with plain K8s manifests instead of Bitnami Helm charts.

12. **Traefik chart v34 schema**: `gateway.listeners` is a map (`web: {port: 8000}`), not an array. Ports are Traefik internal (8000/8443), not external (80/443).

13. **Gateway `namespacePolicy: All`**: Without this, HTTPRoutes in staging/production can't reference the Gateway in the traefik namespace. Error: `NotAllowedByListeners`.

14. **Pin CNPG operator chart version**: Wildcard `0.*` causes auto-upgrades that trigger endless PG pod restart loops (bootstrap image version mismatch). Pin to `0.25.0`.

15. **PG password changes on cluster recreation**: If you delete and recreate a PG Cluster CR, CloudNativePG generates new passwords. You must update `DATABASE_URL` in the app secrets.

16. **Stuck PVCs**: After deleting PG clusters, PVCs can get stuck in `Terminating`. Fix: `kubectl patch pvc <name> -n <ns> -p '{"metadata":{"finalizers":null}}' --type=merge`

### TLS

17. **cert-manager Gateway API needs both settings**: `featureGates: ExperimentalGatewayAPISupport=true` AND `extraArgs: [--enable-gateway-api]` in the Helm values. Also needs a pod restart after changing.

18. **Delete challenges after config change**: Old challenges don't retry with the new config. Delete them and let cert-manager recreate.

---

## 12. Troubleshooting

### Pods in ImagePullBackOff
```bash
kubectl describe pod <name> -n <ns>
```
- **403 Forbidden**: GHCR package is private. Check `ghcr-credentials` secret exists and GHCR package permissions.
- **Not found**: Image tag doesn't exist. Verify with `docker buildx imagetools inspect ghcr.io/<user>/notafilia:<tag>`.

### Web pods in Init:CrashLoopBackOff
The `migrate` init container can't connect to PostgreSQL.
```bash
kubectl get clusters.postgresql.cnpg.io -A           # Check PG health
kubectl logs -n <ns> <web-pod> -c migrate --tail=20   # Check error
```
Common causes: PG not ready yet (wait), wrong password in secret (update `DATABASE_URL`).

### PostgreSQL in restart loop
```bash
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=30 | grep -i restart
```
If "old bootstrap container image" appears: delete the Cluster CR and PVCs, let ArgoCD recreate. Pin the operator version.

### 503 from Traefik
```bash
kubectl get pods -n <ns> -l app.kubernetes.io/component=web   # Are pods Ready?
kubectl describe httproute notafilia -n <ns>                   # Check route status
```
- Pods not Ready → check init container / readiness probe
- `NotAllowedByListeners` → Gateway needs `namespacePolicy: All`

### Certificate not issuing
```bash
kubectl get certificate -n traefik
kubectl get challenges -A
kubectl describe challenge -n traefik <name>
```
- `gateway api is not enabled` → restart cert-manager after adding `--enable-gateway-api`
- Challenges still pending → delete challenges and certificate, let ArgoCD recreate

### Insufficient CPU
```bash
kubectl describe pod <name> -n <ns> | grep "Insufficient cpu"
```
Add more nodes in OVH console (Node pools tab → increase count).

---

## 13. Common Operations

### Deploy a new app version to staging

Push to `main` → CI builds and pushes image → dispatches to infra repo → staging overlay auto-updated → ArgoCD syncs within 30 seconds. No manual step needed.

### Promote staging to production

Push a version tag — CI handles everything:

```bash
git tag v1.1.0
git push origin v1.1.0
# CI builds → dispatches to infra repo → staging + production auto-update
```

### Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
```

### Connect to PostgreSQL

```bash
# Get password
kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d

# Port-forward
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432

# Connect (in another terminal)
psql -h 127.0.0.1 -p 5433 -U notafilia -d notafilia
```

### Run Django management commands

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py <command>
```

### View all ArgoCD app statuses

```bash
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

### Check cluster resource usage

```bash
kubectl top nodes
kubectl top pods -n staging
```
