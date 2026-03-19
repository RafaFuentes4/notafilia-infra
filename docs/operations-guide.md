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

### How CI/CD works

```
Push to main → GitHub Actions → builds linux/amd64 image → pushes to GHCR
  Tags: {commit-sha} + staging-latest
```

The workflow file is at `notafilia/.github/workflows/build-and-push.yml`.

### Deploy to staging (automatic via CI)

Every push to `main` auto-builds. To deploy:

```bash
# 1. Push your code changes to main
cd ~/Developer/notafilia
git add . && git commit -m "your change" && git push

# 2. Wait for GitHub Actions to finish (~3-5 min)
gh run list --repo RafaFuentes4/notafilia --limit 1
# Wait until STATUS shows "completed" + "success"

# 3. Restart pods to pull the new staging-latest image
use-notafilia
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n staging

# 4. Watch the rollout
kubectl rollout status deployment notafilia-web -n staging

# 5. Verify
curl -s https://staging.notafilia.es/up
```

### Deploy to staging (manual, without CI)

```bash
cd ~/Developer/notafilia

# Build for amd64 and push directly
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/rafafuentes4/notafilia:staging-latest \
  --push .

# Restart pods
use-notafilia
kubectl rollout restart deployment notafilia-web notafilia-celery notafilia-beat -n staging
```

### Promote to production (full workflow)

Production uses pinned version tags (e.g., `v1.0.0`, `v1.1.0`). Here's the complete workflow:

```bash
# 1. Make sure staging is working and tested
curl -s https://staging.notafilia.es/up  # Should return OK

# 2. Decide on the version number
VERSION="v1.1.0"

# 3. Tag the current staging image with the production version
#    (no rebuild needed — just re-tag the existing image)
docker pull --platform linux/amd64 ghcr.io/rafafuentes4/notafilia:staging-latest
docker tag ghcr.io/rafafuentes4/notafilia:staging-latest ghcr.io/rafafuentes4/notafilia:$VERSION
docker push ghcr.io/rafafuentes4/notafilia:$VERSION

# 4. Update the production overlay in the infra repo
cd ~/Developer/notafilia-infra
cd overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:$VERSION
cd ../..

# 5. Commit and push the infra change
git add overlays/production/kustomization.yaml
git commit -m "Promote $VERSION to production"
git push

# 6. ArgoCD auto-syncs within 3 minutes, or force it:
argocd app sync notafilia-production --grpc-web

# 7. Watch the rollout
kubectl rollout status deployment notafilia-web -n production

# 8. Verify
curl -s https://notafilia.es/up
```

### Alternative: Tag with GitHub Release

You can also trigger production builds via GitHub tags:

```bash
cd ~/Developer/notafilia

# 1. Create a Git tag
git tag v1.1.0
git push origin v1.1.0

# 2. Create a GitHub Release (optional, nice for changelog)
gh release create v1.1.0 --title "v1.1.0" --notes "Description of changes"
```

To make this auto-build, add a tag trigger to the CI workflow:

```yaml
# In .github/workflows/build-and-push.yml, add to the 'on' section:
on:
  push:
    branches: [main]
    tags: ['v*']      # Also trigger on version tags
```

And add a conditional tag in the build step:

```yaml
tags: |
  ghcr.io/rafafuentes4/notafilia:${{ github.sha }}
  ghcr.io/rafafuentes4/notafilia:staging-latest
  ${{ startsWith(github.ref, 'refs/tags/v') && format('ghcr.io/rafafuentes4/notafilia:{0}', github.ref_name) || '' }}
```

Then promoting to production becomes:

```bash
# 1. Tag and push in the app repo
cd ~/Developer/notafilia
git tag v1.1.0 && git push origin v1.1.0

# 2. Wait for CI to build the tagged image
gh run list --repo RafaFuentes4/notafilia --limit 1

# 3. Update production overlay in infra repo
cd ~/Developer/notafilia-infra/overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:v1.1.0
cd ../..
git commit -am "Promote v1.1.0 to production" && git push
```

### Rollback

#### Quick rollback (temporary)

```bash
# Undo the last deployment — K8s reverts to previous ReplicaSet
kubectl rollout undo deployment notafilia-web -n production
kubectl rollout undo deployment notafilia-celery -n production
kubectl rollout undo deployment notafilia-beat -n production
```

> **Note**: ArgoCD will revert this within 3 minutes (self-heal). Use this for immediate relief while you fix the Git state.

#### Permanent rollback (via Git)

```bash
cd ~/Developer/notafilia-infra/overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:v1.0.0  # Previous version
cd ../..
git commit -am "Rollback production to v1.0.0" && git push
```

### Check deployment status

```bash
# Is the rollout complete?
kubectl rollout status deployment notafilia-web -n staging

# What image is currently running?
kubectl get pods -n staging -l app.kubernetes.io/component=web \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# Deployment history
kubectl rollout history deployment notafilia-web -n staging

# Check GitHub Actions build status
gh run list --repo RafaFuentes4/notafilia --limit 5
```

---

## 7. Per-Branch Deployments (Preview Environments)

Deploy a feature branch to its own namespace with its own URL (e.g., `feature-xyz.notafilia.es`).

### Step 1: Create the namespace

```bash
BRANCH=feature-xyz
kubectl create namespace $BRANCH
```

### Step 2: Create imagePullSecret

```bash
gh auth token | xargs -I {} kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=RafaFuentes4 \
  --docker-password={} \
  -n $BRANCH
```

### Step 3: Build and push the branch image

```bash
cd ~/Developer/notafilia
git checkout feature-xyz

docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t ghcr.io/rafafuentes4/notafilia:$BRANCH \
  --push .
```

### Step 4: Create the secrets

```bash
# Get staging PG password (reuse staging DB, or create a new PG cluster)
STAGING_PG_PASS=$(kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d)

kubectl apply -n $BRANCH -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: notafilia-secrets
type: Opaque
stringData:
  SECRET_KEY: "$(python3 -c 'from secrets import token_urlsafe; print(token_urlsafe(50))')"
  DATABASE_URL: "postgresql://notafilia:${STAGING_PG_PASS}@notafilia-pg-rw.staging:5432/notafilia"
  REDIS_URL: "redis://redis-master.staging:6379/1"
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

> **Note**: This reuses the staging PostgreSQL (same database!) and Redis (different DB index: `/1`). For full isolation, create a separate PG Cluster CR in the new namespace.

### Step 5: Deploy with Kustomize

Create a temporary overlay:

```bash
mkdir -p /tmp/preview-$BRANCH

cat > /tmp/preview-$BRANCH/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $BRANCH
resources:
  - ../../Developer/notafilia-infra/base
patches:
  - target:
      kind: HTTPRoute
      name: notafilia
    patch: |-
      - op: replace
        path: /spec/hostnames/0
        value: ${BRANCH}.notafilia.es
  - target:
      kind: ConfigMap
      name: notafilia-config
    patch: |-
      - op: replace
        path: /data/ALLOWED_HOSTS
        value: "${BRANCH}.notafilia.es"
images:
  - name: ghcr.io/rafafuentes4/notafilia
    newTag: $BRANCH
EOF

kubectl apply -k /tmp/preview-$BRANCH/
```

### Step 6: Add DNS record

Add an A record for `feature-xyz.notafilia.es` → `57.128.58.136`

Or use a wildcard: `*.notafilia.es` → `57.128.58.136` (then any branch works without manual DNS).

### Step 7: Update Django Site

```bash
kubectl exec -n $BRANCH deployment/notafilia-web -c web -- \
  python manage.py shell -c "
from django.contrib.sites.models import Site
site = Site.objects.get(id=1)
site.domain = '${BRANCH}.notafilia.es'
site.save()
"
```

### Cleanup

```bash
kubectl delete namespace $BRANCH
# This deletes everything in the namespace (pods, services, secrets, PVCs)
```

### Automating preview environments

For full automation, you can use ArgoCD ApplicationSets with a Pull Request generator:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: preview-environments
  namespace: argocd
spec:
  generators:
    - pullRequest:
        github:
          owner: RafaFuentes4
          repo: notafilia
        requeueAfterSeconds: 60
  template:
    metadata:
      name: "preview-{{branch}}"
    spec:
      source:
        repoURL: https://github.com/RafaFuentes4/notafilia-infra.git
        path: overlays/staging  # Use staging as base
        targetRevision: main
      destination:
        server: https://kubernetes.default.svc
        namespace: "preview-{{branch}}"
```

This auto-creates/destroys preview environments for every open PR. Full setup requires additional work (image building per PR, DNS wildcard, etc.).

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
