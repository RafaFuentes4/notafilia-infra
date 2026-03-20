# Deploy Cheatsheet

## Release a new version

```bash
# 1. Tag (triggers CI build)
cd ~/Developer/notafilia
git tag v0.4.0 && git push origin v0.4.0

# 2. Wait for build
gh run list --repo RafaFuentes4/notafilia --limit 1 --watch
```

## Deploy to staging

```bash
cd ~/Developer/notafilia-infra

# Option A: one-liner with sed (preserves YAML formatting)
sed -i '' 's/newTag: .*/newTag: "0.4.0"/' overlays/staging/kustomization.yaml && \
  git add overlays/staging && git commit -m "chore: deploy 0.4.0 to staging" && git push

# Option B: kustomize edit (reformats YAML but always correct)
cd overlays/staging && kustomize edit set image ghcr.io/rafafuentes4/notafilia:0.4.0 && cd ../.. && \
  git add overlays/staging && git commit -m "chore: deploy 0.4.0 to staging" && git push

# Option C: edit manually
# Open overlays/staging/kustomization.yaml → change newTag: "0.4.0" → save
git add overlays/staging && git commit -m "chore: deploy 0.4.0 to staging" && git push
```

## Deploy to production

```bash
cd ~/Developer/notafilia-infra

# Same options as staging, just change the path:
sed -i '' 's/newTag: .*/newTag: "0.4.0"/' overlays/production/kustomization.yaml && \
  git add overlays/production && git commit -m "chore: deploy 0.4.0 to production" && git push
```

## Verify

```bash
use-notafilia
kubectl get pods -n staging
kubectl get pods -n production
curl -s https://staging.notafilia.es/up
curl -s https://notafilia.es/up
```

## Rollback

```bash
cd ~/Developer/notafilia-infra
sed -i '' 's/newTag: .*/newTag: "0.3.0"/' overlays/production/kustomization.yaml && \
  git add overlays/production && git commit -m "chore: rollback production to 0.3.0" && git push
```

## Status

```bash
use-notafilia
notafilia-status  # If you added the shell function

# Or manually:
kubectl get applications -n argocd
kubectl get pods -n staging
kubectl get pods -n production
```

## Logs

```bash
kubectl logs -n staging -l app.kubernetes.io/component=web -c web --tail=50 -f
```

## Django commands

```bash
kubectl exec -n staging deployment/notafilia-web -c web -- python manage.py <command>
```

## Preview environment

```bash
cd ~/Developer/notafilia-infra
./scripts/preview-create.sh my-feature    # Create
./scripts/preview-destroy.sh my-feature   # Destroy
```

## Tags

```bash
cd ~/Developer/notafilia
git tag --list 'v*' --sort=-v:refname     # List versions
```
