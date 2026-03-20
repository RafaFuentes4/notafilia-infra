# Notafilia K8s — Operations Guide

Practical recipes for common tasks on the cluster. Assumes you have `kubectl` configured and `use-notafilia` alias set up.

---

## Table of Contents

1. [Daily Development Workflow](#1-daily-development-workflow)
2. [Running Django Commands](#2-running-django-commands)
3. [Connecting to Databases](#3-connecting-to-databases)
4. [Viewing Logs](#4-viewing-logs)
5. [Managing Secrets](#5-managing-secrets)
6. [Deploying New Versions](#6-deploying-new-versions)
7. [Per-Branch Deployments (Preview Environments)](#7-per-branch-deployments-preview-environments)
8. [Port-Forwarding for Local Development](#8-port-forwarding-for-local-development)
9. [Scaling](#9-scaling)
10. [Debugging Failed Deployments](#10-debugging-failed-deployments)
11. [Database Operations](#11-database-operations)
12. [Certificate & TLS Management](#12-certificate--tls-management)
13. [ArgoCD Operations](#13-argocd-operations)
14. [Cluster Maintenance](#14-cluster-maintenance)
15. [Emergency Procedures](#15-emergency-procedures)

---

## 1. Daily Morning Checklist

Run this every morning before starting work. Copy-paste the whole block:

```bash
use-notafilia

echo "=== 1. NODES ==="
kubectl get nodes
echo ""

echo "=== 2. ARGOCD APPS ==="
kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
echo ""

echo "=== 3. STAGING PODS ==="
kubectl get pods -n staging
echo ""

echo "=== 4. PRODUCTION PODS ==="
kubectl get pods -n production
echo ""

echo "=== 5. PG CLUSTERS ==="
kubectl get clusters.postgresql.cnpg.io -A
echo ""

echo "=== 6. TLS CERTIFICATE ==="
kubectl get certificate -n traefik
echo ""

echo "=== 7. ENDPOINTS ==="
echo -n "Staging:    " && curl -sk -o /dev/null -w "%{http_code}" https://staging.notafilia.es/up && echo ""
echo -n "Production: " && curl -sk -o /dev/null -w "%{http_code}" https://notafilia.es/up && echo ""
```

### What "healthy" looks like

| Check | Expected |
|-------|----------|
| Nodes | 2/2 Ready |
| ArgoCD apps | All 7 Synced + Healthy |
| Staging pods | 5/5 Running (web, celery, beat, pg, redis) |
| Production pods | 5/5 Running |
| PG clusters | Both "Cluster in healthy state" |
| TLS certificate | READY = True |
| Endpoints | Both return 200 |

### What to do if something is wrong

| Symptom | Action |
|---------|--------|
| A pod is `CrashLoopBackOff` | `kubectl logs -n <ns> <pod> --previous` — check the crash reason |
| A pod is `ImagePullBackOff` | Image tag doesn't exist or `ghcr-credentials` expired. See [Section 10](#10-debugging-failed-deployments) |
| ArgoCD app is `OutOfSync` | `argocd app sync <name> --grpc-web` — force sync |
| ArgoCD app is `Degraded` | Click into it in the ArgoCD UI to see which resource is unhealthy |
| PG cluster not healthy | `kubectl describe cluster notafilia-pg -n <ns>` — check status/events |
| TLS cert not ready | `kubectl get challenges -A` — check if ACME challenge is stuck |
| Endpoint returns 503 | Web pods aren't Ready. Check pod status and logs |
| Node is `NotReady` | Check OVH console — node may be rebooting for security updates |

### Optional: Add as a shell function

Add to `~/.zshrc`:

```bash
notafilia-status() {
  use-notafilia
  echo "=== NODES ===" && kubectl get nodes
  echo "" && echo "=== ARGOCD ===" && kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
  echo "" && echo "=== STAGING ===" && kubectl get pods -n staging
  echo "" && echo "=== PRODUCTION ===" && kubectl get pods -n production
  echo "" && echo "=== PG ===" && kubectl get clusters.postgresql.cnpg.io -A
  echo "" && echo "=== TLS ===" && kubectl get certificate -n traefik
  echo "" && echo "=== ENDPOINTS ==="
  echo -n "Staging:    " && curl -sk -o /dev/null -w "%{http_code}\n" https://staging.notafilia.es/up
  echo -n "Production: " && curl -sk -o /dev/null -w "%{http_code}\n" https://notafilia.es/up
}
```

Then just run `notafilia-status` every morning.

### Watch pods in real-time

```bash
kubectl get pods -n staging --watch
```

---

## 2. Running Django Commands

### One-off commands

```bash
# Any manage.py command
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py <command> [args]

# Examples:
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py shell
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py showmigrations
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py createsuperuser
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py collectstatic --noinput
```

### Interactive shell

```bash
kubectl exec -it -n staging deployment/notafilia-web -c web -- python manage.py shell
```

### Promote a user to superuser

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py promote_user_to_superuser user@example.com
```

### Update the Django Site object

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py shell -c "
from django.contrib.sites.models import Site
site = Site.objects.get(id=1)
site.domain = 'staging.notafilia.es'
site.name = 'Notafilia Staging'
site.save()
print(f'Updated: {site.domain}')
"
```

### Run a command in production

Same commands, just change `-n staging` to `-n production`:

```bash
kubectl exec -n production deployment/notafilia-web -c web -- \
  python manage.py showmigrations
```

---

## 3. Connecting to Databases

### PostgreSQL via port-forward

```bash
# Terminal 1: Start port-forward
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432

# Terminal 2: Connect with psql
# Get the password first:
kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d

# Connect:
psql -h 127.0.0.1 -p 5433 -U notafilia -d notafilia
# Paste the password when prompted
```

For production:

```bash
kubectl port-forward -n production svc/notafilia-pg-rw 5434:5432
kubectl get secret notafilia-pg-app -n production -o jsonpath='{.data.password}' | base64 -d
psql -h 127.0.0.1 -p 5434 -U notafilia -d notafilia
```

### GUI database tool (DataGrip, DBeaver, etc.)

With the port-forward running:

| Field | Staging | Production |
|-------|---------|------------|
| Host | 127.0.0.1 | 127.0.0.1 |
| Port | 5433 | 5434 |
| Database | notafilia | notafilia |
| User | notafilia | notafilia |
| Password | (from Secret) | (from Secret) |

### Redis via port-forward

```bash
kubectl port-forward -n staging svc/redis-master 6380:6379

# Connect with redis-cli
redis-cli -h 127.0.0.1 -p 6380
```

### Shell aliases (add to ~/.zshrc)

```bash
alias pg-notafilia-stg='kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432'
alias pg-notafilia-prod='kubectl port-forward -n production svc/notafilia-pg-rw 5434:5432'
alias redis-notafilia-stg='kubectl port-forward -n staging svc/redis-master 6380:6379'
```

---

## 4. Viewing Logs

### Application logs

```bash
# Web (Gunicorn) — last 100 lines
kubectl logs -n staging -l app.kubernetes.io/component=web -c web --tail=100

# Web (Gunicorn) — follow in real-time
kubectl logs -n staging -l app.kubernetes.io/component=web -c web -f

# Migration init container (last run)
kubectl logs -n staging -l app.kubernetes.io/component=web -c migrate --tail=50

# Celery worker
kubectl logs -n staging -l app.kubernetes.io/component=celery --tail=100

# Celery beat
kubectl logs -n staging -l app.kubernetes.io/component=beat --tail=50
```

### Infrastructure logs

```bash
# PostgreSQL
kubectl logs -n staging notafilia-pg-1 --tail=50

# Traefik
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50

# cert-manager
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=50

# CloudNativePG operator
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=50

# ArgoCD
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

### Logs from a crashed pod (previous instance)

```bash
kubectl logs -n staging <pod-name> --previous
```

### Events (very useful for debugging)

```bash
kubectl get events -n staging --sort-by='.lastTimestamp' | tail -20
```

---

## 5. Managing Secrets

### View current secret keys (not values)

```bash
kubectl get secret notafilia-secrets -n staging -o jsonpath='{.data}' | python3 -c "
import json, sys
for k in json.load(sys.stdin):
    print(k)
"
```

### View a specific secret value

```bash
kubectl get secret notafilia-secrets -n staging \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

### Update a secret value

```bash
kubectl patch secret notafilia-secrets -n staging --type merge \
  -p '{"stringData":{"ANTHROPIC_API_KEY":"sk-ant-your-new-key"}}'

# Restart pods to pick up the change
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n staging
```

### Add a new secret key

```bash
kubectl patch secret notafilia-secrets -n staging --type merge \
  -p '{"stringData":{"NEW_VARIABLE":"new-value"}}'
```

### Add a new env var (non-secret)

Edit `base/configmap.yaml`, commit, push. ArgoCD syncs it. Then restart pods:

```bash
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n staging
```

> **Important**: ConfigMap and Secret changes don't auto-restart pods. You must `rollout restart` after changing them.

### Encrypt secrets with SOPS (for Git)

```bash
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt

# Encrypt
sops -e -i overlays/staging/secrets.enc.yaml

# Decrypt (view only)
sops -d overlays/staging/secrets.enc.yaml

# Edit encrypted file (decrypts in editor, re-encrypts on save)
sops overlays/staging/secrets.enc.yaml
```

---

## 6. Deploying New Versions

### How CI/CD works (fully automated)

There are two deployment flows depending on whether you're deploying to staging or production:

**Staging (fully automatic — zero manual steps after push):**

```
Push to main
  → GitHub Actions builds image (tags: sha-xxx + staging-latest)
    → CI dispatches to notafilia-infra repo
      → Infra CI updates staging overlay tag → commits → pushes
        → ArgoCD detects change → deploys new pods
```

**Production (one manual step — create a version tag):**

```
Create tag v0.2.0 → push tag
  → GitHub Actions builds image (tags: 0.2.0 + 0.2 + sha-xxx)
    → CI dispatches to notafilia-infra repo
      → Infra CI updates BOTH staging + production tags → commits → pushes
        → ArgoCD detects change → deploys new pods in both envs
```

### Pipeline components

| Repo | Workflow | Triggers on | What it does |
|------|----------|-------------|-------------|
| `notafilia` | `build-and-push.yml` | Push to `main`, tags `v*` | Builds Docker image, pushes to GHCR, dispatches to infra repo |
| `notafilia-infra` | `update-image.yml` | `repository_dispatch` from app CI | Updates image tag in kustomization overlays, commits, pushes |
| `notafilia-infra` | ArgoCD (in-cluster) | Git poll every ~3 min | Detects tag change, rolls out new pods |

### Workflow A: Deploy to staging (automatic)

You just push code. Everything else is automated.

```bash
cd ~/Developer/notafilia

# 1. Make your changes on a feature branch
git checkout -b feature/my-change
# ... edit code ...

# 2. Run checks locally (same ones CI runs)
make ruff                    # Python linting + formatting
make npm-type-check          # TypeScript checks
make test ARGS='--keepdb'    # Django tests

# 3. Commit
git add . && git commit -m "feat: description of change"

# 4. Merge to main and push
git checkout main
git merge feature/my-change
git push

# 5. Done! Everything happens automatically:
#    - GitHub Actions builds image (~1-3 min)
#    - Infra repo gets auto-updated (~30 sec after build)
#    - ArgoCD deploys new pods (~1-3 min after infra update)
#    Total: ~3-5 minutes from push to live

# 6. (Optional) Watch the pipeline
gh run list --repo RafaFuentes4/notafilia --limit 1     # App CI
gh run list --repo RafaFuentes4/notafilia-infra --limit 1  # Infra CI

# 7. (Optional) Verify
curl -s https://staging.notafilia.es/up
```

### Workflow B: Deploy to staging AND production (version tag)

When you're ready to release, create a version tag. This deploys to both environments.

```bash
cd ~/Developer/notafilia

# 1. Make sure main is up to date and staging works
git checkout main && git pull
curl -s https://staging.notafilia.es/up   # Should return OK

# 2. Create a version tag
git tag v0.2.0
git push origin v0.2.0

# 3. Done! The pipeline:
#    - Builds image with tag 0.2.0
#    - Updates BOTH staging and production overlays in infra repo
#    - ArgoCD deploys to both environments

# 4. (Optional) Watch
gh run list --repo RafaFuentes4/notafilia --limit 2
gh run list --repo RafaFuentes4/notafilia-infra --limit 1

# 5. Verify both environments
curl -s https://staging.notafilia.es/up
curl -s https://notafilia.es/up

# 6. Check what's running
use-notafilia
kubectl get pods -n staging -l app.kubernetes.io/component=web \
  -o jsonpath='{.items[0].spec.containers[0].image}'
# Should show: ghcr.io/rafafuentes4/notafilia:0.2.0
```

### Workflow C: Deploy only to production (promote existing image)

If staging already has the right version and you just want to promote it to production:

```bash
cd ~/Developer/notafilia-infra

# Update only the production overlay
cd overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:0.2.0
cd ../..
git add overlays/production && git commit -m "chore: promote 0.2.0 to production" && git push

# ArgoCD deploys within ~3 minutes
```

### Deploy manually (without CI, for debugging)

```bash
cd ~/Developer/notafilia

# Build directly from local code
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/rafafuentes4/notafilia:manual-test \
  --push .

# Update infra repo manually
cd ~/Developer/notafilia-infra/overlays/staging
kustomize edit set image ghcr.io/rafafuentes4/notafilia:manual-test
cd ../..
git commit -am "chore: deploy manual-test to staging" && git push
```

### Rollback

#### Quick rollback (immediate, temporary)

```bash
use-notafilia
kubectl rollout undo deployment notafilia-web -n production
kubectl rollout undo deployment notafilia-celery -n production
kubectl rollout undo deployment notafilia-beat -n production
```

> **Note**: ArgoCD will revert this within 3 minutes (self-heal). Use this for immediate relief while you fix the Git state.

#### Permanent rollback (via Git)

```bash
cd ~/Developer/notafilia-infra/overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:0.1.0  # Previous version
cd ../..
git commit -am "chore: rollback production to 0.1.0" && git push
```

### Check deployment status

```bash
# Is the rollout complete?
kubectl rollout status deployment notafilia-web -n staging

# What image is currently running?
kubectl get pods -n staging -l app.kubernetes.io/component=web \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# What image is production running?
kubectl get pods -n production -l app.kubernetes.io/component=web \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# Deployment history
kubectl rollout history deployment notafilia-web -n staging

# Check GitHub Actions build status
gh run list --repo RafaFuentes4/notafilia --limit 5

# Check infra auto-update status
gh run list --repo RafaFuentes4/notafilia-infra --limit 5
```

### Version numbering convention

Follow [semver](https://semver.org/):
- **Patch** (`0.1.1`) — bug fixes, small changes
- **Minor** (`0.2.0`) — new features, non-breaking changes
- **Major** (`1.0.0`) — breaking changes, major milestones

```bash
# See existing tags
cd ~/Developer/notafilia
git tag --list 'v*' --sort=-v:refname

# Current: v0.1.0
```

### CI/CD setup (for reference)

These are already configured. Documenting here so you know what exists:

**Secrets needed:**

| Secret | Repo | Purpose |
|--------|------|---------|
| `INFRA_REPO_PAT` | `notafilia` | Fine-grained PAT with Contents: Read/Write on `notafilia-infra`. Used to trigger `repository_dispatch`. |
| `DEPLOY_PAT` | `notafilia-infra` | Same PAT. Used to `git push` the tag update commit. |

**GHCR package:** Set to **Public** visibility so pods can pull without `imagePullSecrets`.
Package settings: https://github.com/users/RafaFuentes4/packages/container/notafilia/settings

**PAT renewal:** The fine-grained PAT may have an expiration. When it expires, CI will fail at the "Update staging in infra repo" step. Regenerate it and update both secrets.

---

## 7. Preview Environments (Per-Branch Deployments)

Preview environments let you test a feature branch on a real URL before merging to main. Each branch gets its own isolated deployment at `<branch-name>.notafilia.es`.

### What happens when you create a preview

The `preview-create.sh` script does all of this for you:

1. **Builds a Docker image** from your branch code (linux/amd64)
2. **Pushes it to GHCR** with the branch name as the tag
3. **Creates a K8s namespace** named after the branch
4. **Copies secrets** from the staging namespace (reuses staging database)
5. **Deploys** the app using the staging Kustomize overlay with branch-specific patches
6. **Updates the Django Site** object so API URLs work correctly

The result: a fully working copy of the app at `http://<branch>.notafilia.es`.

### Prerequisites (one-time setup)

**Wildcard DNS** — Already configured. A `*.notafilia.es` A record points to `57.128.58.136`. Any subdomain works automatically.

**GHCR public** — Already configured. No imagePullSecret needed.

**jq installed** — The script uses `jq` to copy secrets. Install with `brew install jq` if needed.

### Quick start

```bash
cd ~/Developer/notafilia-infra

# Create a preview environment
./scripts/preview-create.sh my-feature

# Your app is at: http://my-feature.notafilia.es

# When done, tear it down
./scripts/preview-destroy.sh my-feature
```

### Full walkthrough (tested and verified)

Here's the exact workflow we tested with a real change:

#### Step 1: Create a feature branch with your changes

```bash
cd ~/Developer/notafilia
git checkout -b my-cool-feature

# Make your changes
# For example, edit templates/web/components/hero.html

# Commit (don't push to main — this is just for preview)
git add . && git commit -m "feat: my cool feature"
```

#### Step 2: Run the preview script

```bash
cd ~/Developer/notafilia-infra
./scripts/preview-create.sh my-cool-feature
```

What you'll see:

```
=== Creating preview environment ===
Branch:    my-cool-feature
Namespace: my-cool-feature
Domain:    my-cool-feature.notafilia.es
Image:     ghcr.io/rafafuentes4/notafilia:my-cool-feature

>>> Building Docker image...
[... Docker build output ...]

>>> Creating namespace my-cool-feature...
namespace/my-cool-feature created

>>> Copying secrets from staging...
secret/notafilia-secrets created

>>> Deploying...
configmap/notafilia-config created
service/notafilia-web created
deployment.apps/notafilia-beat created
deployment.apps/notafilia-celery created
deployment.apps/notafilia-web created
httproute.gateway.networking.k8s.io/notafilia created

>>> Waiting for pods...
deployment "notafilia-web" successfully rolled out

>>> Updating Django Site...
Site updated: my-cool-feature.notafilia.es

=== Preview environment ready ===
URL: http://my-cool-feature.notafilia.es
```

Total time: ~2-3 minutes (mostly Docker build + image push).

#### Step 3: Test your changes

Open `http://my-cool-feature.notafilia.es` in your browser. You should see your changes live.

You can also check the pods:

```bash
use-notafilia
kubectl get pods -n my-cool-feature
```

#### Step 4: Make more changes (optional)

If you need to iterate, rebuild and redeploy:

```bash
cd ~/Developer/notafilia
# Make more changes, commit...

# Rebuild the image
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/rafafuentes4/notafilia:my-cool-feature \
  --push .

# Restart pods to pick up the new image
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n my-cool-feature
```

#### Step 5: Tear down when done

```bash
cd ~/Developer/notafilia-infra
./scripts/preview-destroy.sh my-cool-feature
```

This deletes the entire namespace and everything in it (pods, services, secrets). The Docker image stays in GHCR but that's fine — it doesn't cost anything.

#### Step 6: Merge to main (normal workflow)

```bash
cd ~/Developer/notafilia
git checkout main
git merge my-cool-feature
git push
# CI auto-deploys to staging
```

### How it works under the hood

The preview environment:

- **Reuses the staging PostgreSQL database** — your preview shares the same data as staging. This means you can test with real data, but also means database changes in the preview affect staging. For full isolation, you'd need a separate PG cluster (not covered by the script).
- **Reuses staging Redis** — same Redis instance, same database index.
- **Gets its own namespace** — all K8s resources (pods, services, configmaps) are isolated in a namespace named after the branch.
- **Routes via Gateway API** — Traefik's wildcard DNS + the HTTPRoute resource route `<branch>.notafilia.es` to the preview's web service.
- **No HTTPS** — preview environments use HTTP only. The TLS certificate only covers `notafilia.es` and `staging.notafilia.es`. Wildcard certs require DNS-01 challenges which need DNS provider API integration.

### Multiple preview environments

You can run multiple preview environments simultaneously:

```bash
./scripts/preview-create.sh feature-auth
./scripts/preview-create.sh feature-billing
./scripts/preview-create.sh bugfix-login

# Three separate deployments:
# http://feature-auth.notafilia.es
# http://feature-billing.notafilia.es
# http://bugfix-login.notafilia.es

# List all preview namespaces
kubectl get namespaces | grep -v -E "staging|production|argocd|cert-manager|cnpg|traefik|kube|default"

# Tear down individually
./scripts/preview-destroy.sh feature-auth
```

Be mindful of cluster resources — each preview environment runs 3 pods (web, celery, beat). With 2 nodes, you can comfortably run 2-3 previews alongside staging and production.

### Troubleshooting preview environments

#### Pods in CrashLoopBackOff
```bash
kubectl logs -n my-feature deployment/notafilia-web -c migrate --tail=20
```
Usually means the staging PG is not reachable or the password changed. Destroy and recreate.

#### "Connection refused" on the URL
The pods might not be ready yet. Check:
```bash
kubectl get pods -n my-feature
```
Wait for all pods to show `1/1 Running`.

#### API errors / "bad request"
The Django Site object might not have been updated. Fix manually:
```bash
kubectl exec -n my-feature deployment/notafilia-web -c web -- \
  python manage.py shell -c "
from django.contrib.sites.models import Site
site = Site.objects.get(id=1)
site.domain = 'my-feature.notafilia.es'
site.save()
"
```

#### Branch name has slashes (e.g., `feature/my-thing`)
K8s namespace names can't contain slashes. Use dashes: `feature-my-thing`.

#### Script fails with "kubectl connection refused"
The script sets the kubectl context automatically, but if you have a port-forward running on port 8080 (ArgoCD), kill it first:
```bash
lsof -ti:8080 | xargs kill 2>/dev/null
```

---

## 8. Port-Forwarding for Local Development

### Run local Django code against staging databases

This is useful when you want to develop locally but test against real data.

```bash
# Terminal 1: Forward staging PostgreSQL
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432

# Terminal 2: Forward staging Redis
kubectl port-forward -n staging svc/redis-master 6380:6379

# Terminal 3: Run local Django with staging env vars
cd ~/Developer/notafilia
export DATABASE_URL="postgresql://notafilia:<staging-pg-password>@127.0.0.1:5433/notafilia"
export REDIS_URL="redis://127.0.0.1:6380/0"
export DJANGO_SETTINGS_MODULE="notafilia.settings"
python manage.py runserver
```

> **Warning**: This connects to the REAL staging database. Be careful with destructive operations.

### Run local Django against production (read-only recommended)

```bash
# Use the read-only PG endpoint to be safe
kubectl port-forward -n production svc/notafilia-pg-r 5434:5432
```

### Forward the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
```

### Forward the Traefik dashboard

```bash
kubectl port-forward -n traefik deployment/traefik 9000:9000
# Open http://localhost:9000/dashboard/
```

---

## 9. Scaling

### Scale web replicas

```bash
# Temporarily (ArgoCD will revert to Git state)
kubectl scale deployment notafilia-web -n staging --replicas=3

# Permanently: edit the overlay
# overlays/staging/kustomization.yaml or overlays/production/kustomization.yaml
# Add/modify the replicas patch, commit, push
```

### Add more nodes

OVH Manager → Managed Kubernetes → notafilia → Node pools → `general` → increase count.

New nodes are ready in ~2-3 minutes. K8s automatically schedules pods onto them.

### Check resource usage

```bash
kubectl top nodes                    # CPU/memory per node
kubectl top pods -n staging          # CPU/memory per pod
kubectl top pods -A --sort-by=cpu    # Highest CPU across all namespaces
```

### Scale PostgreSQL (add read replica)

Edit the Cluster CR to increase instances:

```yaml
# infrastructure/cloudnative-pg/cluster-production.yaml
spec:
  instances: 2  # Was 1, now adds a read replica
```

Commit and push. CloudNativePG operator creates the replica automatically. The `notafilia-pg-r` service routes read-only queries to replicas.

---

## 10. Debugging Failed Deployments

### Step-by-step debugging flow

```bash
# 1. Check pod status
kubectl get pods -n staging

# 2. If pod is in CrashLoopBackOff, check logs
kubectl logs -n staging <pod-name> --previous

# 3. If pod is in Init:Error, check init container logs
kubectl logs -n staging <pod-name> -c migrate

# 4. If pod is Pending, check events
kubectl describe pod <pod-name> -n staging
# Look at "Events" section — common issues:
#   - Insufficient cpu/memory → add nodes or reduce requests
#   - ImagePullBackOff → check image tag, registry credentials
#   - Unbound PVC → check storage class

# 5. If pod is Running but not Ready, check probes
kubectl describe pod <pod-name> -n staging | grep -A5 "Readiness"

# 6. Check service endpoints
kubectl get endpoints notafilia-web -n staging
# If "none" → no ready pods

# 7. Check ArgoCD sync status
argocd app get notafilia-staging --grpc-web

# 8. Check events cluster-wide
kubectl get events -n staging --sort-by='.lastTimestamp' | tail -20
```

### Common issues and fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ImagePullBackOff` | Private registry, wrong tag | Check `ghcr-credentials`, verify image exists |
| `Init:CrashLoopBackOff` | Migration fails (PG not ready, wrong password) | Check PG cluster health, verify DATABASE_URL |
| `CrashLoopBackOff` | App crash on start | Check logs: `kubectl logs <pod> --previous` |
| `Pending` | Not enough resources | `kubectl describe pod` → check Events for "Insufficient" |
| `OOMKilled` | Memory limit exceeded | Increase memory limits in deployment |
| `exec format error` | Wrong architecture (ARM image on x86 node) | Rebuild with `--platform linux/amd64` |
| `DisallowedHost` | ALLOWED_HOSTS mismatch | Update ConfigMap overlay, restart pods |
| `Connection refused` to PG | PG not ready or wrong service name | Check `kubectl get clusters.postgresql.cnpg.io -A` |

---

## 11. Database Operations

### Run migrations manually

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py migrate
```

### Check migration status

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- \
  python manage.py showmigrations
```

### Create a database dump

```bash
# Start port-forward in background
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432 &
PF_PID=$!

# Get password
PG_PASS=$(kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d)

# Dump
PGPASSWORD=$PG_PASS pg_dump -h 127.0.0.1 -p 5433 -U notafilia -d notafilia \
  --format=custom -f backup_staging_$(date +%Y%m%d).pgdump

# Stop port-forward
kill $PF_PID
```

### Restore from a dump

```bash
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432 &
PF_PID=$!

PG_PASS=$(kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d)

PGPASSWORD=$PG_PASS pg_restore -h 127.0.0.1 -p 5433 -U notafilia -d notafilia \
  --clean --if-exists backup_staging_20260319.pgdump

kill $PF_PID
```

### Copy production data to staging

```bash
# Dump production
kubectl port-forward -n production svc/notafilia-pg-rw 5434:5432 &
PROD_PID=$!
PROD_PASS=$(kubectl get secret notafilia-pg-app -n production -o jsonpath='{.data.password}' | base64 -d)
PGPASSWORD=$PROD_PASS pg_dump -h 127.0.0.1 -p 5434 -U notafilia -d notafilia \
  --format=custom -f prod_dump.pgdump
kill $PROD_PID

# Restore to staging
kubectl port-forward -n staging svc/notafilia-pg-rw 5433:5432 &
STG_PID=$!
STG_PASS=$(kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d)
PGPASSWORD=$STG_PASS pg_restore -h 127.0.0.1 -p 5433 -U notafilia -d notafilia \
  --clean --if-exists prod_dump.pgdump
kill $STG_PID
```

### PostgreSQL cluster health

```bash
kubectl get clusters.postgresql.cnpg.io -A
# STATUS should be "Cluster in healthy state"
```

---

## 12. Certificate & TLS Management

### Check certificate status

```bash
kubectl get certificate -n traefik
# READY = True means it's valid

kubectl describe certificate notafilia-tls -n traefik
# Shows expiry date, renewal status
```

### Add a new domain to the certificate

Edit `infrastructure/cert-manager/certificate.yaml`:

```yaml
spec:
  dnsNames:
    - notafilia.es
    - staging.notafilia.es
    - preview.notafilia.es    # Add new domain
```

Commit and push. cert-manager re-issues the certificate with the new domain.

### Force certificate renewal

```bash
kubectl delete certificate notafilia-tls -n traefik
# ArgoCD recreates it, cert-manager re-issues
```

### Check ACME challenges

```bash
kubectl get challenges -A
# State should be "valid" or empty (completed)
```

---

## 13. ArgoCD Operations

### Access the UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Login: admin / <password from initial setup>
```

### Get admin password

```bash
argocd admin initial-password -n argocd
```

### Check all application statuses

```bash
kubectl get applications -n argocd -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

### Force sync an application

```bash
argocd app sync notafilia-staging --grpc-web
```

### View application diff (what would change)

```bash
argocd app diff notafilia-staging --grpc-web
```

### Hard refresh (re-read from Git)

```bash
argocd app get notafilia-staging --grpc-web --hard-refresh
```

### Disable auto-sync temporarily (for debugging)

```bash
kubectl patch application notafilia-staging -n argocd \
  --type merge -p '{"spec":{"syncPolicy":null}}'

# Re-enable:
kubectl patch application notafilia-staging -n argocd \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## 14. Cluster Maintenance

### Check node health

```bash
kubectl get nodes -o wide
kubectl describe node <node-name>  # Check conditions, capacity, allocatable
```

### Drain a node (for maintenance)

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
# Pods are rescheduled to other nodes

# After maintenance:
kubectl uncordon <node-name>
```

### Update kubectl context after kubeconfig refresh

If OVH rotates credentials:

```bash
# Download new kubeconfig from OVH Manager
mv ~/Downloads/kubeconfig-*.yml ~/.kube/notafilia-ovh.yaml
```

### Check storage usage

```bash
kubectl get pvc -A
# Shows capacity and status of all persistent volumes
```

### Clean up completed jobs

```bash
kubectl delete jobs --field-selector status.successful=1 -A
```

---

## 15. Emergency Procedures

### App is completely down

```bash
# 1. Check what's broken
kubectl get pods -n staging
kubectl get applications -n argocd

# 2. Check events
kubectl get events -n staging --sort-by='.lastTimestamp' | tail -10

# 3. If pods are crashing, check logs
kubectl logs -n staging -l app.kubernetes.io/component=web -c web --previous

# 4. If the problem is recent, rollback
kubectl rollout undo deployment notafilia-web -n staging
```

### Database is down

```bash
# Check PG cluster
kubectl get clusters.postgresql.cnpg.io -A
kubectl describe cluster notafilia-pg -n staging

# If stuck in restart loop, delete and recreate (DATA LOSS!)
kubectl delete cluster notafilia-pg -n staging
kubectl delete pvc -n staging -l cnpg.io/cluster=notafilia-pg
# ArgoCD recreates from Git → fresh empty database
# Then restart pods: kubectl rollout restart deployment ...
```

### TLS certificate expired

```bash
kubectl delete certificate notafilia-tls -n traefik
# ArgoCD recreates, cert-manager re-issues within minutes
```

### ArgoCD is stuck

```bash
# Terminate stuck operation
argocd app terminate-op <app-name> --grpc-web

# If ArgoCD itself is broken
kubectl rollout restart deployment argocd-server argocd-repo-server -n argocd
```

### Need to access the cluster but ArgoCD is down

ArgoCD being down doesn't affect running pods. Your app stays running. You can still use `kubectl` directly:

```bash
kubectl apply -k overlays/staging/   # Direct Kustomize apply, bypasses ArgoCD
```

### Nuclear option: Delete everything and start fresh

```bash
# This destroys ALL data. Only use if nothing else works.
kubectl delete namespace staging
kubectl delete namespace production
kubectl create namespace staging
kubectl create namespace production
# Re-apply secrets, imagePullSecrets, then let ArgoCD recreate everything
```
