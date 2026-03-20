# Preview Environments — Architecture & Replication Guide

This document explains how the preview environment system works in notafilia-infra, the architectural pattern behind it, and how to replicate it in other projects (like bettergy-charts).

---

## The Problem

You want to test a feature branch before merging to main. Staging is shared — you can't deploy your branch there without disrupting others. You need an isolated, temporary deployment of the app at a unique URL.

## The Solution

A script that creates a full copy of the app in its own Kubernetes namespace, accessible at `<branch-name>.notafilia.es`, using the same cluster infrastructure (database, redis, routing).

---

## How It Works (Notafilia)

### Architecture

```
Permanent infrastructure (shared):
├── Traefik (LoadBalancer: 57.128.58.136)
├── Gateway API + wildcard DNS (*.notafilia.es)
├── PostgreSQL (staging namespace — shared by preview envs)
└── Redis (staging namespace — shared by preview envs)

Preview environment (per branch):
└── Namespace: <branch-name>
    ├── ConfigMap (ALLOWED_HOSTS: <branch>.notafilia.es)
    ├── Secret (copied from staging)
    ├── Deployment: notafilia-web
    ├── Deployment: notafilia-celery
    ├── Deployment: notafilia-beat
    ├── Service: notafilia-web
    └── HTTPRoute: notafilia → <branch>.notafilia.es
```

### Key design decisions

1. **Namespace isolation** — Each preview gets its own namespace. All resources (pods, services, configmaps) are isolated. Deleting the namespace cleans up everything.

2. **Shared database** — Preview environments connect to the staging PostgreSQL. This means:
   - Pros: No setup time, real data to test against
   - Cons: Database changes in the preview affect staging
   - For full isolation, you'd create a separate PG Cluster CR in the preview namespace

3. **Shared Redis** — Same Redis instance as staging. Each preview could use a different Redis DB index (`/1`, `/2`, etc.) for isolation, but in practice it doesn't matter for short-lived previews.

4. **Wildcard DNS** — A `*.notafilia.es` A record points to the Traefik LoadBalancer. Any subdomain works without adding DNS records per branch.

5. **Gateway API routing** — Traefik's Gateway has `namespacePolicy: All`, which allows HTTPRoutes in any namespace to attach to it. Each preview creates its own HTTPRoute with a unique hostname.

6. **Kustomize as the template engine** — Instead of maintaining a separate Helm chart for previews, we render the staging overlay and use `sed` to patch the namespace, hostname, and image tag. Simple, no extra files.

7. **Django Site object update** — Pegasus/Django uses the `django.contrib.sites` framework for absolute URLs. After deploying, we update the Site record to match the preview domain.

### The scripts

**`scripts/preview-create.sh <branch-name>`**

```bash
#!/bin/bash
# Simplified flow:

# 1. Build Docker image from current branch code
docker buildx build --platform linux/amd64 \
  -t ghcr.io/rafafuentes4/notafilia:<branch> --push .

# 2. Create K8s namespace
kubectl create namespace <branch>

# 3. Copy secrets from staging (same DB credentials)
kubectl get secret notafilia-secrets -n staging -o json \
  | jq '.metadata.namespace = "<branch>"' \
  | kubectl apply -f -

# 4. Render staging overlay → sed-patch namespace/hostname/image → apply
kubectl kustomize overlays/staging/ \
  | sed "s/namespace: staging/namespace: <branch>/g" \
  | sed "s/staging.notafilia.es/<branch>.notafilia.es/g" \
  | sed "s|ghcr.io/rafafuentes4/notafilia:[^ \"]*|ghcr.io/rafafuentes4/notafilia:<branch>|g" \
  | kubectl apply -f -

# 5. Wait for rollout
kubectl rollout status deployment notafilia-web -n <branch>

# 6. Update Django Site object
kubectl exec -n <branch> deployment/notafilia-web -c web -- \
  python manage.py shell -c "
from django.contrib.sites.models import Site
site = Site.objects.get(id=1)
site.domain = '<branch>.notafilia.es'
site.save()
"
```

**`scripts/preview-destroy.sh <branch-name>`**

```bash
#!/bin/bash
# Deletes the entire namespace — all resources gone
kubectl delete namespace <branch>
```

### Prerequisites

| Requirement | Why | How to set up |
|-------------|-----|---------------|
| Wildcard DNS | Any subdomain resolves without manual DNS | Add `*.notafilia.es → <LoadBalancer IP>` A record |
| Public container registry | Pods can pull without imagePullSecrets | Set GHCR package to Public |
| Gateway `namespacePolicy: All` | HTTPRoutes from any namespace can attach | Set in Traefik Helm values |
| `jq` installed | Script uses it to patch JSON | `brew install jq` |
| Staging secrets exist | Copied into preview namespace | Must have `notafilia-secrets` in staging |

---

## How to Replicate for Bettergy

Bettergy uses FluxCD + Helm charts instead of ArgoCD + Kustomize. The pattern is the same but the tools differ.

### Bettergy architecture differences

| | Notafilia | Bettergy |
|---|-----------|----------|
| GitOps | ArgoCD | FluxCD |
| App packaging | Kustomize overlays | Helm charts (HelmRelease) |
| Routing | Gateway API (HTTPRoute) | Ingress (ingress-nginx) |
| Secrets | kubectl apply | Sealed Secrets |
| Registry | GHCR (public) | GitLab Registry (private) |

### Adapted pattern for Bettergy

#### Step 1: Wildcard DNS

Add a wildcard A record: `*.energysequence.com → <cluster-LoadBalancer-IP>`

(Or `*.stg.energysequence.com` if you want to scope previews to a subdomain.)

#### Step 2: Create the preview script

```bash
#!/bin/bash
set -euo pipefail

BRANCH="${1:?Usage: $0 <branch-name>}"
NAMESPACE="preview-${BRANCH}"
DOMAIN="${BRANCH}.stg.energysequence.com"
IMAGE_TAG="${BRANCH}"

# Ensure correct cluster context
kubectl config use-context kubernetes-admin@bettergy-staging

echo "=== Creating preview: $BRANCH ==="

# 1. Create namespace
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

# 2. Copy secrets from staging
# Option A: Copy sealed secrets and unseal in new namespace
# Option B: Copy the already-decrypted secrets from staging
kubectl get secret app-secrets -n energysequence -o json \
  | jq ".metadata.namespace = \"$NAMESPACE\" | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels)" \
  | kubectl apply -f -

# 3. Create a HelmRelease for the preview
# This is the Bettergy equivalent of "kubectl kustomize | sed | apply"
cat <<EOF | kubectl apply -f -
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: preview-${BRANCH}
  namespace: ${NAMESPACE}
spec:
  interval: 30s
  targetNamespace: ${NAMESPACE}
  releaseName: preview-${BRANCH}
  chart:
    spec:
      chart: ./charts/app/
      interval: 1m
      sourceRef:
        kind: GitRepository
        name: bettergy-charts
        namespace: flux-system
  values:
    replicas: 1
    environment: preview
    hostname: ${DOMAIN}
    image:
      name: registry.gitlab.com/bettergy/energy-sequence/app/www
      tag: ${IMAGE_TAG}
    # Point to staging database (shared)
    database:
      host: postgresql.postgresql.svc.cluster.local
      name: stg_caes_db
      user: stg_caes_admin
      password: REDACTED
      port: 5432
    # Ingress for this preview
    ingress:
      enabled: true
      hostname: ${DOMAIN}
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-prod
EOF

# 4. Wait for deployment
echo "Waiting for pods..."
kubectl rollout status deployment preview-${BRANCH}-app -n "$NAMESPACE" --timeout=180s 2>/dev/null || true

echo ""
echo "=== Preview ready: https://${DOMAIN} ==="
echo "Destroy: kubectl delete namespace ${NAMESPACE}"
```

#### Step 3: Destroy script

```bash
#!/bin/bash
BRANCH="${1:?Usage: $0 <branch-name>}"
NAMESPACE="preview-${BRANCH}"
kubectl delete namespace "$NAMESPACE"
```

### Key adaptations for Bettergy

1. **HelmRelease instead of Kustomize** — Instead of rendering Kustomize and sed-patching, create a HelmRelease CR that points to the existing chart with preview-specific values.

2. **Ingress instead of HTTPRoute** — Bettergy uses ingress-nginx, so the preview needs an Ingress resource (usually created by the Helm chart's ingress values).

3. **Sealed Secrets** — You can't just `jq` copy sealed secrets to a new namespace because they're encrypted for a specific namespace. Options:
   - Copy the *decrypted* secret from staging (simpler, works for previews)
   - Create a new sealed secret for the preview namespace (more secure)
   - Use the `--scope cluster-wide` flag when sealing secrets (allows any namespace)

4. **GitLab Registry** — If using a private registry, create an `imagePullSecret` in the preview namespace:
   ```bash
   kubectl create secret docker-registry gitlab-registry \
     --docker-server=registry.gitlab.com \
     --docker-username=<user> \
     --docker-password=<token> \
     -n $NAMESPACE
   ```

5. **FluxCD reconciliation** — FluxCD will try to reconcile the HelmRelease if you create it in a namespace that Flux watches. To avoid conflicts:
   - Use a namespace prefix that Flux doesn't watch (e.g., `preview-*`)
   - Or apply the HelmRelease directly with `kubectl apply` instead of committing to Git

---

## Generic Pattern (for any project)

The preview environment pattern is tool-agnostic. Here's the abstract recipe:

```
1. Build image from branch code
2. Create isolated namespace
3. Copy/create secrets
4. Deploy the app (same manifests as staging, patched for preview)
5. Create routing rule (Ingress/HTTPRoute with branch-specific hostname)
6. (Optional) Post-deploy hooks (Django Site update, seed data, etc.)
```

### Checklist for adding preview environments to any K8s project

- [ ] **Wildcard DNS** — `*.yourdomain.com → LoadBalancer IP`
- [ ] **Wildcard or on-demand TLS** — cert-manager with DNS-01 challenge, or HTTP-only for previews
- [ ] **Cross-namespace routing** — Ingress/Gateway must accept routes from preview namespaces
- [ ] **Shared vs isolated database** — Decide if previews share staging DB or get their own
- [ ] **Image registry access** — Public registry or imagePullSecret in preview namespace
- [ ] **Secret management** — How to get app secrets into the preview namespace
- [ ] **Cleanup strategy** — Manual destroy script, or auto-cleanup after N days / PR close
- [ ] **Resource limits** — Ensure preview pods have low resource requests to fit on the cluster

### Advanced: Auto-create/destroy on PR open/close

For full automation, use ArgoCD ApplicationSets (or FluxCD equivalent):

```yaml
# ArgoCD ApplicationSet — creates/destroys preview envs per PR
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: preview-environments
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
        path: overlays/staging
        targetRevision: main
      destination:
        server: https://kubernetes.default.svc
        namespace: "preview-{{branch}}"
      syncPolicy:
        automated:
          prune: true
```

This auto-creates an ArgoCD Application for every open PR and deletes it when the PR is closed. Requires additional setup for image building per PR and namespace bootstrapping.
