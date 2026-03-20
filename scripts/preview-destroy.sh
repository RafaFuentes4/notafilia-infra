#!/bin/bash
set -euo pipefail

# Usage: ./scripts/preview-destroy.sh <branch-name>
# Destroys a preview environment

BRANCH="${1:?Usage: $0 <branch-name>}"
NAMESPACE="${BRANCH}"

# Ensure correct kubectl context
export KUBECONFIG="$HOME/.kube/kubeconfig-production.yml:$HOME/.kube/kubeconfig-staging.yml:$HOME/.kube/notafilia-ovh.yaml"
kubectl config use-context kubernetes-admin@notafilia > /dev/null

echo "=== Destroying preview environment ==="
echo "Namespace: $NAMESPACE"
echo ""

read -p "Are you sure? This deletes everything in $NAMESPACE. [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
  kubectl delete namespace "$NAMESPACE"
  echo ""
  echo "=== Preview environment destroyed ==="
else
  echo "Cancelled."
fi
