#!/bin/bash
set -euo pipefail

# Usage: ./scripts/preview-create.sh <branch-name>
# Creates a preview environment for a feature branch

BRANCH="${1:?Usage: $0 <branch-name>}"
NAMESPACE="${BRANCH}"
DOMAIN="${BRANCH}.notafilia.es"
IMAGE="ghcr.io/rafafuentes4/notafilia:${BRANCH}"
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$(cd "$INFRA_DIR/../notafilia" && pwd)"

# Ensure correct kubectl context
export KUBECONFIG="$HOME/.kube/kubeconfig-production.yml:$HOME/.kube/kubeconfig-staging.yml:$HOME/.kube/notafilia-ovh.yaml"
kubectl config use-context kubernetes-admin@notafilia > /dev/null

echo "=== Creating preview environment ==="
echo "Branch:    $BRANCH"
echo "Namespace: $NAMESPACE"
echo "Domain:    $DOMAIN"
echo "Image:     $IMAGE"
echo ""

# 1. Build and push the image
echo ">>> Building Docker image..."
cd "$APP_DIR"
docker buildx build --platform linux/amd64 \
  -f Dockerfile.web \
  -t "$IMAGE" \
  --push .

# 2. Create namespace
echo ""
echo ">>> Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || echo "Namespace already exists"

# 3. Copy secrets from staging
echo ">>> Copying secrets from staging..."
kubectl get secret notafilia-secrets -n staging -o json \
  | jq ".metadata.namespace = \"$NAMESPACE\" | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations)" \
  | kubectl apply -f -

# 4. Deploy using kustomize with inline patches
echo ">>> Deploying..."
cd "$INFRA_DIR"
kubectl kustomize overlays/staging/ \
  | sed "s/namespace: staging/namespace: $NAMESPACE/g" \
  | sed "s/staging\.notafilia\.es/$DOMAIN/g" \
  | sed "s|ghcr.io/rafafuentes4/notafilia:[^ \"]*|$IMAGE|g" \
  | kubectl apply -f -

# 5. Wait for pods
echo ""
echo ">>> Waiting for pods..."
kubectl rollout status deployment notafilia-web -n "$NAMESPACE" --timeout=180s 2>/dev/null || true

# 6. Update Django Site
echo ">>> Updating Django Site..."
sleep 5
kubectl exec -n "$NAMESPACE" deployment/notafilia-web -c web -- \
  python manage.py shell -c "
from django.contrib.sites.models import Site
site = Site.objects.get(id=1)
site.domain = '$DOMAIN'
site.name = 'Notafilia Preview ($BRANCH)'
site.save()
print(f'Site updated: {site.domain}')
" 2>/dev/null || echo "Could not update Site (pods may still be starting)"

echo ""
echo "=== Preview environment ready ==="
echo "URL: http://$DOMAIN"
echo ""
echo "To tear down: ./scripts/preview-destroy.sh $BRANCH"
