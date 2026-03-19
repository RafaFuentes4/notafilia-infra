# Notafilia K8s Infrastructure — Step-by-Step Setup Guide

This guide documents every step taken to deploy the Notafilia Django application to Kubernetes on OVH. A junior developer should be able to follow this from scratch to get a running deployment.

---

## Prerequisites

### Tools to install (macOS)

```bash
brew install kubectl argocd helm sops age kustomize
```

### Accounts needed
- **OVH Public Cloud** account with billing configured
- **GitHub** account with the `notafilia` and `notafilia-infra` repos
- **Domain registrar** access for DNS (we use GoDaddy for `notafilia.es`)

---

## Phase 1: Repository Setup

### 1.1 Create the infra repo

```bash
cd ~/Developer
mkdir notafilia-infra && cd notafilia-infra
git init
```

### 1.2 Create directory structure

```bash
mkdir -p base
mkdir -p overlays/staging overlays/production
mkdir -p infrastructure/traefik infrastructure/cert-manager
mkdir -p infrastructure/cloudnative-pg infrastructure/redis
mkdir -p argocd docs
```

### 1.3 Create all manifest files

The complete file contents are in `docs/implementation-spec.md`. Here's what each file does:

**`base/`** — Kustomize base manifests (environment-agnostic):
- `kustomization.yaml` — Lists all resources, applies `app.kubernetes.io/name: notafilia` labels
- `deployment-web.yaml` — Gunicorn deployment with init container for `manage.py migrate`
- `deployment-celery.yaml` — Celery worker (`--pool threads --concurrency 20`)
- `deployment-beat.yaml` — Celery beat (replicas: 1, strategy: Recreate to avoid duplicate tasks)
- `service-web.yaml` — ClusterIP service on port 8000
- `configmap.yaml` — Non-secret env vars (DJANGO_SETTINGS_MODULE, ALLOWED_HOSTS, etc.)
- `httproute.yaml` — Gateway API route pointing to notafilia-web:8000

**`overlays/staging/`** — Patches for staging:
- `kustomization.yaml` — Sets namespace: staging, host: staging.notafilia.es, image tag: staging-latest
- `secrets.enc.yaml` — SOPS-encrypted secrets (DATABASE_URL, SECRET_KEY, etc.)

**`overlays/production/`** — Patches for production:
- `kustomization.yaml` — Sets namespace: production, host: notafilia.es, image tag: v1.0.0

**`infrastructure/`** — Third-party services as ArgoCD Applications:
- `traefik/application.yaml` — Traefik v3 Helm chart with Gateway API + LoadBalancer
- `cert-manager/application.yaml` — cert-manager Helm chart
- `cert-manager/cluster-issuer.yaml` — Let's Encrypt ClusterIssuer (sync-wave: 1)
- `cloudnative-pg/application.yaml` — CNPG operator Helm chart (pinned to 0.25.0, ServerSideApply)
- `cloudnative-pg/cluster-staging.yaml` — PG cluster: 1 instance, 10Gi (sync-wave: 1)
- `cloudnative-pg/cluster-production.yaml` — PG cluster: 1 instance, 20Gi (sync-wave: 1)
- `redis/staging.yaml` — redis:7-alpine Deployment + PVC + Service
- `redis/production.yaml` — Same for production namespace

**`argocd/`** — App-of-apps bootstrap:
- `app-of-apps.yaml` — Root Application that manages the `argocd/` directory
- `infrastructure.yaml` — Scans `infrastructure/` recursively with SkipDryRunOnMissingResource
- `staging.yaml` — Points to `overlays/staging` (Kustomize)
- `production.yaml` — Points to `overlays/production` (prune: false for safety)

### 1.4 Validate locally

```bash
kubectl kustomize base/                  # Should render valid YAML
kubectl kustomize overlays/staging/      # Should show staging patches applied
kubectl kustomize overlays/production/   # Should show production patches applied
```

### 1.5 Key gotchas discovered during Phase 1

1. **Use `labels` instead of `commonLabels`** in kustomization.yaml — `commonLabels` is deprecated.
2. **Bitnami images are no longer free** (Broadcom ended the program Sep 2025). Use official `redis:7-alpine` with plain manifests instead of the Bitnami Helm chart.
3. **All deployments need `imagePullSecrets`** if using a private GHCR registry.
4. **Health probes must use `/up`** (middleware-based), not `/health/` — the latter is blocked by Django's `ALLOWED_HOSTS` when accessed via pod IP.

---

## Phase 2: OVH Cluster

### 2.1 Create the cluster

Go to **OVH Manager → Public Cloud → Managed Kubernetes → Create a cluster**:

| Setting | Value |
|---------|-------|
| Name | `notafilia` |
| Region | Gravelines (GRA9), 1-AZ |
| Plan | Free |
| K8s version | Latest stable (1.34) |
| Security policy | Maximum security (recommended) |
| Private network | None (public IPs) |
| Node pool | B3-8 (8GB RAM, 2 vCPU), **2 nodes** |
| Auto-scaling | Off |
| Anti-affinity | Off |
| Billing | Hourly |
| Pool name | `general` |

> **Important:** Use 2 nodes minimum. A single B3-8 node doesn't have enough CPU for all infrastructure + app pods. We initially tried 1 node and hit `Insufficient cpu` scheduling failures.

Wait ~5-10 minutes for the cluster to provision.

### 2.2 Configure kubectl

Download the kubeconfig from OVH Manager and save it:

```bash
# Move the downloaded file
mv ~/Downloads/kubeconfig-*.yml ~/.kube/notafilia-ovh.yaml

# Add to KUBECONFIG in ~/.zshrc
export KUBECONFIG="$HOME/.kube/notafilia-ovh.yaml"
# (or append to existing KUBECONFIG with colon separator)

# Add convenience alias
alias use-notafilia='kubectl config use-context kubernetes-admin@notafilia'

# Verify
source ~/.zshrc
use-notafilia
kubectl get nodes  # Should show 2 Ready nodes
```

### 2.3 Create namespaces

```bash
kubectl create namespace staging
kubectl create namespace production
```

### 2.4 Verify storage class

```bash
kubectl get storageclass
# Should show csi-cinder-high-speed (default) — this is what our PG manifests use
```

### 2.5 Generate SOPS encryption keys

```bash
# Generate age keypair
age-keygen -o ~/.config/sops/age/keys.txt
# Output shows: Public key: age1xxxxxx...

# BACK UP THE PRIVATE KEY to a password manager (1Password, etc.)
# If lost, you'll need to re-encrypt all secrets
cat ~/.config/sops/age/keys.txt
```

Update `.sops.yaml` with your real public key and commit.

---

## Phase 3: ArgoCD + Infrastructure

### 3.1 Install ArgoCD

```bash
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# If you get "annotations too long" error on applicationsets CRD:
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts

# Wait for all pods
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s

# Get admin password
argocd admin initial-password -n argocd

# Access the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080, login with admin + password above
```

### 3.2 Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### 3.3 Mount SOPS age key in ArgoCD

```bash
# Create the secret
kubectl create secret generic age-key \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt \
  -n argocd

# Patch repo-server to mount it
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

# Wait for restart
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=120s
```

### 3.4 Deploy the app-of-apps

```bash
# This single command bootstraps EVERYTHING
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD will:
1. Read `argocd/` directory → create child Applications
2. `notafilia-infrastructure` scans `infrastructure/` → creates Traefik, cert-manager, CNPG, Redis
3. `notafilia-staging` and `notafilia-production` deploy app overlays

### 3.5 Key gotchas discovered during Phase 3

1. **CRD ordering**: CloudNativePG Cluster CRs and ClusterIssuers depend on CRDs from their operators. Use `argocd.argoproj.io/sync-wave: "1"` annotations on dependent resources and `SkipDryRunOnMissingResource=true` on the infrastructure Application.

2. **Traefik chart v34 schema change**: `gateway.listeners` must be a map (`web: {port: 8000}`) not an array (`- name: web`). Ports are Traefik internal ports (8000/8443), not external (80/443).

3. **Gateway `namespacePolicy: All`**: Without this, HTTPRoutes in staging/production namespaces can't reference the Gateway in the traefik namespace. You'll see `NotAllowedByListeners` in the HTTPRoute status.

4. **CloudNativePG `poolers` CRD too large**: Requires `ServerSideApply=true` in the operator's ArgoCD Application.

5. **Don't use wildcard chart versions** (`0.*`) for CNPG: Auto-upgrades cause bootstrap image version mismatches that put PG clusters in endless restart loops. Pin to a specific version like `0.25.0`.

6. **`ServerSideApply` conflicts with `--force`** in ArgoCD retry loops: Don't use both. Use `SkipDryRunOnMissingResource` alone on the infrastructure Application.

---

## Phase 4: App Deployment

### 4.1 Build and push Docker image

> **Critical**: Build for `linux/amd64` — OVH nodes are x86_64, your Mac is ARM.

```bash
cd ~/Developer/notafilia

# Login to GHCR (need write:packages scope)
gh auth refresh -h github.com -s write:packages,read:packages
gh auth token | docker login ghcr.io -u <your-github-username> --password-stdin

# Build for amd64 and push
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/<your-github-username>/notafilia:staging-latest \
  --push .

# Also tag for production
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/<your-github-username>/notafilia:v1.0.0 \
  --push .
```

> **Gotcha**: If you build without `--platform linux/amd64`, the image will be ARM and you'll get `exec format error` in the pods.

### 4.2 Create imagePullSecret

GHCR packages are private by default. Pods need credentials to pull:

```bash
gh auth token | xargs -I {} kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password={} \
  -n staging

gh auth token | xargs -I {} kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password={} \
  -n production
```

All deployments reference this secret via `imagePullSecrets: [{name: ghcr-credentials}]` in the pod spec.

### 4.3 Create secrets in the cluster

Get the auto-generated PostgreSQL passwords:

```bash
# Staging
kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d
# Production
kubectl get secret notafilia-pg-app -n production -o jsonpath='{.data.password}' | base64 -d
```

Generate a Django SECRET_KEY:

```bash
python3 -c "from secrets import token_urlsafe; print(token_urlsafe(50))"
```

Create the secrets (replace placeholders):

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
  SECRET_KEY: "<generated-secret-key>"
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

Repeat for production (use the production PG password and `redis-master.production`).

> **Important**: The `argocd.argoproj.io/compare-options: IgnoreExtraneous` annotation prevents ArgoCD from pruning secrets it doesn't manage. Without this, ArgoCD deletes the secret on every sync because it's not in the Kustomize resources.

> **Note on SOPS**: The secrets files in the repo are SOPS-encrypted for Git safety. However, ArgoCD doesn't have a SOPS decryption plugin configured yet, so secrets are applied directly to the cluster with `kubectl apply`. This will be improved in a future phase.

### 4.4 Restart deployments

After secrets and images are in place:

```bash
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n staging
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n production
```

### 4.5 Key gotchas discovered during Phase 4

1. **GHCR token scope**: The default `gh auth` token doesn't have `write:packages`. Run `gh auth refresh -h github.com -s write:packages,read:packages` first.

2. **Build architecture**: Always use `docker buildx build --platform linux/amd64`. Without this, ARM images cause `exec format error`.

3. **PG password changes on cluster recreation**: If you ever delete and recreate the PG Cluster CR, CloudNativePG generates a new password. You must update the `DATABASE_URL` in the cluster secret.

4. **CNPG bootstrap image upgrade loop**: If the CNPG operator auto-upgrades, it tries to update the bootstrap container image in existing PG pods, causing endless restarts. Fix: delete the Cluster CR and PVCs, let ArgoCD recreate them fresh. Pin the operator chart version to prevent recurrence.

5. **Stuck PVCs during cleanup**: PVCs from deleted CNPG clusters can get stuck in `Terminating`. Fix with: `kubectl patch pvc <name> -n <ns> -p '{"metadata":{"finalizers":null}}' --type=merge`

---

## Phase 5: DNS

### 5.1 Get the Traefik external IP

```bash
kubectl get svc -n traefik
# EXTERNAL-IP column shows the LoadBalancer IP (e.g., 57.128.58.136)
```

### 5.2 Configure DNS records

In your domain registrar (GoDaddy, Cloudflare, etc.), add two A records:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `@` | `57.128.58.136` | 600 |
| A | `staging` | `57.128.58.136` | 600 |

### 5.3 Verify

```bash
# Wait for DNS propagation (usually <10 minutes with 600s TTL)
dig +short notafilia.es
dig +short staging.notafilia.es

# Test the app
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://staging.notafilia.es/up
# Should return: HTTP 200
```

---

## Current State (as of 2026-03-19)

### What's working
- **Both staging and production** return HTTP 200
- **All 7 ArgoCD Applications** are Synced
- **6 of 7** are Healthy (Traefik shows Degraded until TLS is configured)
- **PostgreSQL** healthy in both namespaces (CloudNativePG operator)
- **Redis** running in both namespaces (official image)
- **Traefik** routing via Gateway API with external IP `57.128.58.136`
- **DNS** configured: `notafilia.es` and `staging.notafilia.es`
- **Docker images** on GHCR: `staging-latest` and `v1.0.0`

### What's not yet done
- **TLS/HTTPS**: cert-manager and ClusterIssuer are deployed but no Certificate resource is created yet. The app works on HTTP only.
- **SOPS in ArgoCD**: Secrets are managed manually via `kubectl apply`. KSOPS plugin needs to be configured for full GitOps secret management.
- **CI/CD**: No GitHub Actions workflow yet. Images are built and pushed manually.
- **Static files**: CSS/JS aren't loading because S3 media storage isn't configured with real AWS credentials.
- **Monitoring**: No Prometheus/Grafana. Only Sentry (if DSN is configured in secrets).

### Cluster topology

```
OVH Managed K8s (GRA9, 2× B3-8 nodes)
├── argocd namespace (7 pods)
│   └── ArgoCD server, repo-server, app controller, redis, dex, notifications, applicationset
├── cert-manager namespace (3 pods)
│   └── controller, cainjector, webhook
├── cnpg-system namespace (1 pod)
│   └── CloudNativePG operator
├── traefik namespace (1 pod)
│   └── Traefik proxy (LoadBalancer: 57.128.58.136)
├── staging namespace (5 pods)
│   ├── notafilia-web (Gunicorn, 1 replica)
│   ├── notafilia-celery (worker, 1 replica)
│   ├── notafilia-beat (scheduler, 1 replica)
│   ├── notafilia-pg-1 (PostgreSQL 18, 10Gi)
│   └── redis (7-alpine, 2Gi)
└── production namespace (5 pods)
    ├── notafilia-web (Gunicorn, 1 replica)
    ├── notafilia-celery (worker, 1 replica)
    ├── notafilia-beat (scheduler, 1 replica)
    ├── notafilia-pg-1 (PostgreSQL 18, 20Gi)
    └── redis (7-alpine, 2Gi)
```

### Monthly cost
- 2× B3-8 nodes: ~68€/month (covered by 200€ OVH free trial credit until ~June 2026)
- Cluster control plane: Free (OVH Free plan)
- LoadBalancer: Included
- Block storage (PVCs): ~5€/month for ~36Gi total

---

## Troubleshooting

### Pods stuck in ImagePullBackOff
- Check `kubectl describe pod <name> -n <ns>` for the exact error
- If "403 Forbidden": the GHCR package is private and `ghcr-credentials` imagePullSecret is missing or expired
- If "not found": the image tag doesn't exist. Check `docker buildx imagetools inspect ghcr.io/<user>/notafilia:<tag>`

### Pods stuck in Init:CrashLoopBackOff (web)
- The `migrate` init container can't connect to PostgreSQL
- Check PG cluster status: `kubectl get clusters.postgresql.cnpg.io -A`
- Check PG pod: `kubectl get pods -n <ns> -l cnpg.io/cluster=notafilia-pg`
- Check secret has correct password: `kubectl get secret notafilia-secrets -n <ns> -o jsonpath='{.data.DATABASE_URL}' | base64 -d`

### PostgreSQL cluster in restart loop
- Check if CNPG operator upgraded: `kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=20`
- Look for "old bootstrap container image" messages
- Fix: delete the Cluster CR and PVCs, let ArgoCD recreate. Pin operator chart version.

### 503 Service Unavailable from Traefik
- Web pods aren't Ready: `kubectl get pods -n <ns> -l app.kubernetes.io/component=web`
- Check readiness probe: must use `/up` not `/health/` (Django ALLOWED_HOSTS blocks pod IPs)
- Check HTTPRoute status: `kubectl describe httproute notafilia -n <ns>` — look for `NotAllowedByListeners` (fix: Gateway needs `namespacePolicy: All`)

### ArgoCD Application shows "Unknown"
- The source can't be read. Check `argocd app get <name> --grpc-web` for `ComparisonError`
- Common cause: referencing a plugin that doesn't exist (e.g., `kustomize-sops`)

### Insufficient CPU scheduling failures
- `kubectl describe pod <name>` shows `0/N nodes are available: Insufficient cpu`
- Either add more nodes or reduce resource requests in deployments
- Current requests are minimal (25m-50m CPU per pod)

### Stuck PVCs in Terminating state
```bash
kubectl patch pvc <name> -n <ns> -p '{"metadata":{"finalizers":null}}' --type=merge
```
