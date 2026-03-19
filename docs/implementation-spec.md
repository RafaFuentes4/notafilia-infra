# Notafilia K8s Infrastructure — Implementation Specification

## Overview

This document is the step-by-step implementation spec for deploying Notafilia (a Django app with Celery workers, PostgreSQL, and Redis) to Kubernetes on OVH, using a modern 2026 GitOps stack.

### Technology Stack

| Layer | Tool | Why |
|-------|------|-----|
| GitOps | **ArgoCD** | Visual UI for observing syncs, diffs, resource trees. ~60% GitOps market share (CNCF 2025). |
| App packaging | **Kustomize** | Plain YAML + overlays. Easier to learn than Helm Go templates. |
| Third-party charts | **Helm** | Standard for installing community charts (Redis, cert-manager, Traefik). |
| Ingress | **Traefik + Gateway API** | ingress-nginx EOL March 2026. Gateway API is the official K8s networking future (GA since Oct 2023, v1.4). |
| TLS | **cert-manager** | Undisputed standard. CNCF project, works with Gateway API. |
| Secrets | **SOPS + age** | Value-level encryption, readable diffs, no in-cluster controller needed. |
| PostgreSQL | **CloudNativePG** | Purpose-built operator. Automated failover, backup/restore to S3, declarative. |
| Redis | **Bitnami Helm chart** | Simple, well-maintained. Fine for small/medium projects. |
| CI/CD | **GitHub Actions → GHCR** | Native integration, OIDC auth, free for public repos. |
| Cluster | **OVH Managed K8s** | Single cluster, namespace isolation (staging + production). |

### Existing App Config Reference

These files in the `notafilia` app repo drive configuration decisions:

- **`Dockerfile.web`** — Multi-stage build: Python deps (uv) → Node.js frontend (vite) → runtime (python:3.12-slim-bookworm). Creates non-root `django` user. Entrypoint: `/start`.
- **`docker_startup.sh`** — Runs `python manage.py migrate --noinput` then `gunicorn --bind 0.0.0.0:$PORT --workers 1 --threads 8 --timeout 0 notafilia.wsgi:application`.
- **`config/deploy.yml`** (Kamal) — Defines 3 server roles (web, celery worker, celery beat), env vars (clear + secret), PostgreSQL 17 + Redis accessories.
- **`notafilia/settings_production.py`** — `DEBUG=False`, SSL redirect, secure cookies, HSTS-ready.

---

## Phase 1: Repository + Local Tooling

### Goal
Create the `notafilia-infra` repository with all Kustomize manifests, ArgoCD Application definitions, and SOPS config. Everything should render valid YAML locally before touching a cluster.

### 1.1 Initialize the Repository

```bash
cd /Users/rafa/Developer
mkdir notafilia-infra && cd notafilia-infra
git init
```

Create the directory structure:

```bash
mkdir -p base
mkdir -p overlays/staging overlays/production
mkdir -p infrastructure/traefik infrastructure/cert-manager
mkdir -p infrastructure/cloudnative-pg infrastructure/redis
mkdir -p argocd
```

### 1.2 Kustomize Base Manifests

These define the app's K8s resources in a generic, environment-agnostic way. Overlays will patch in environment-specific values.

#### `base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment-web.yaml
  - deployment-celery.yaml
  - deployment-beat.yaml
  - service-web.yaml
  - configmap.yaml
  - httproute.yaml

commonLabels:
  app.kubernetes.io/name: notafilia
  app.kubernetes.io/managed-by: kustomize
```

#### `base/configmap.yaml`

Non-secret environment variables. These come from `config/deploy.yml`'s `env.clear` section.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: notafilia-config
data:
  DJANGO_SETTINGS_MODULE: "notafilia.settings_production"
  ALLOWED_HOSTS: "*"  # Overridden per environment in overlays
  USE_S3_MEDIA: "True"
  AWS_STORAGE_BUCKET_NAME: "notafilia-media"
  DEFAULT_FROM_EMAIL: "rafafcantero@gmail.com"
  SERVER_EMAIL: "noreply@notafilia.com"
```

**Rationale:** `ALLOWED_HOSTS` is `*` in the base because the actual hostname varies per environment. In production settings, Django validates against this. The overlay patches this to the real domain.

#### `base/deployment-web.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notafilia-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: notafilia
      app.kubernetes.io/component: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: notafilia
        app.kubernetes.io/component: web
    spec:
      initContainers:
        - name: migrate
          image: ghcr.io/rafafuentes4/notafilia:latest  # Overridden by overlay
          command: ["python", "manage.py", "migrate", "--noinput"]
          envFrom:
            - configMapRef:
                name: notafilia-config
            - secretRef:
                name: notafilia-secrets
      containers:
        - name: web
          image: ghcr.io/rafafuentes4/notafilia:latest  # Overridden by overlay
          command:
            - gunicorn
            - --bind=0.0.0.0:8000
            - --workers=1
            - --threads=8
            - --timeout=0
            - notafilia.wsgi:application
          ports:
            - containerPort: 8000
              name: http
              protocol: TCP
          envFrom:
            - configMapRef:
                name: notafilia-config
            - secretRef:
                name: notafilia-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /health/  # Django health check endpoint
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health/
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
```

**Design decisions:**
- **Init container for migrations** instead of running them in the startup script. This is the K8s-native pattern — migrations run once before the main container starts, and if they fail, the pod stays in `Init:Error` state (visible in ArgoCD UI).
- **Gunicorn command specified explicitly** rather than using `/start` entrypoint. This separates the K8s deployment concern from the Docker entrypoint, giving us more control.
- **Resource requests/limits** are conservative starting points. Monitor with `kubectl top pods` and adjust.
- **Health checks** use `/health/` (comprehensive, checks DB + Redis + Celery via `django-health-check`). The app also has `/up` (lightweight middleware-based check). We use `/health/` for readiness (ensures dependencies are reachable) and could use `/up` for liveness if `/health/` proves too heavy.

#### `base/deployment-celery.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notafilia-celery
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: notafilia
      app.kubernetes.io/component: celery
  template:
    metadata:
      labels:
        app.kubernetes.io/name: notafilia
        app.kubernetes.io/component: celery
    spec:
      containers:
        - name: celery
          image: ghcr.io/rafafuentes4/notafilia:latest
          command:
            - celery
            - -A
            - notafilia
            - worker
            - -l
            - INFO
            - --pool
            - threads
            - --concurrency
            - "20"
          envFrom:
            - configMapRef:
                name: notafilia-config
            - secretRef:
                name: notafilia-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

**Note:** The Celery command matches exactly what's in `config/deploy.yml`. The `--pool threads` flag is important — it uses threading instead of forking, which works well with the Django ORM connection pooling.

#### `base/deployment-beat.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notafilia-beat
spec:
  replicas: 1  # MUST be 1 — multiple beat instances cause duplicate scheduled tasks
  strategy:
    type: Recreate  # Never run 2 beat instances simultaneously
  selector:
    matchLabels:
      app.kubernetes.io/name: notafilia
      app.kubernetes.io/component: beat
  template:
    metadata:
      labels:
        app.kubernetes.io/name: notafilia
        app.kubernetes.io/component: beat
    spec:
      containers:
        - name: beat
          image: ghcr.io/rafafuentes4/notafilia:latest
          command:
            - celery
            - -A
            - notafilia
            - beat
            - -l
            - INFO
          envFrom:
            - configMapRef:
                name: notafilia-config
            - secretRef:
                name: notafilia-secrets
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

**Critical:** Beat replicas must always be 1. The `Recreate` strategy ensures zero overlap during deployments — the old pod terminates before the new one starts. This prevents duplicate scheduled tasks.

#### `base/service-web.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: notafilia-web
spec:
  type: ClusterIP
  ports:
    - port: 8000
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: notafilia
    app.kubernetes.io/component: web
```

**Why ClusterIP:** The service is only accessed internally by Traefik (the ingress controller). No need for NodePort or LoadBalancer.

#### `base/httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: notafilia
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik  # Where Traefik is installed
  hostnames:
    - "notafilia.example.com"  # Overridden by overlay
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: notafilia-web
          port: 8000
```

**Why Gateway API instead of Ingress:** The Ingress API is feature-frozen. Gateway API is the official K8s networking standard (GA since Oct 2023). Traefik has full v1.4 conformance. Learning Gateway API now means learning the future-proof pattern.

### 1.3 Overlay for Staging

#### `overlays/staging/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: staging

resources:
  - ../../base
  - secrets.enc.yaml  # SOPS-encrypted secrets

patches:
  # Override the hostname in HTTPRoute
  - target:
      kind: HTTPRoute
      name: notafilia
    patch: |-
      - op: replace
        path: /spec/hostnames/0
        value: staging.notafilia.com

  # Override ALLOWED_HOSTS in ConfigMap
  - target:
      kind: ConfigMap
      name: notafilia-config
    patch: |-
      - op: replace
        path: /data/ALLOWED_HOSTS
        value: "staging.notafilia.com"

images:
  - name: ghcr.io/rafafuentes4/notafilia
    newTag: staging-latest  # Updated by CI/CD or ArgoCD Image Updater
```

#### `overlays/staging/secrets.enc.yaml` (before SOPS encryption)

This is what the file looks like **before** encryption. After running `sops -e`, values are encrypted but keys remain readable (this is the SOPS advantage over Sealed Secrets).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: notafilia-secrets
type: Opaque
stringData:
  SECRET_KEY: "your-staging-secret-key-here"
  DATABASE_URL: "postgresql://notafilia:password@notafilia-pg-rw.staging:5432/notafilia"
  REDIS_URL: "redis://notafilia-redis-master.staging:6379/0"
  AWS_ACCESS_KEY_ID: "your-aws-key"
  AWS_SECRET_ACCESS_KEY: "your-aws-secret"
  SENTRY_DSN: ""
  TURNSTILE_KEY: "your-turnstile-key"
  TURNSTILE_SECRET: "your-turnstile-secret"
  ANTHROPIC_API_KEY: "your-anthropic-key"
  DEFAULT_AI_MODEL: "claude-sonnet-4-6"
  OPENAI_API_KEY: "your-openai-key"
```

**Note on DATABASE_URL:** CloudNativePG creates a service named `<cluster-name>-rw` (read-write endpoint) in the same namespace. The URL references this service.

**Note on REDIS_URL:** Bitnami Redis creates a service named `<release-name>-redis-master`. The URL references this.

### 1.4 Overlay for Production

#### `overlays/production/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: production

resources:
  - ../../base
  - secrets.enc.yaml

patches:
  - target:
      kind: HTTPRoute
      name: notafilia
    patch: |-
      - op: replace
        path: /spec/hostnames/0
        value: notafilia.com

  - target:
      kind: ConfigMap
      name: notafilia-config
    patch: |-
      - op: replace
        path: /data/ALLOWED_HOSTS
        value: "notafilia.com"

  # Production gets more resources
  - target:
      kind: Deployment
      name: notafilia-web
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/cpu
        value: "250m"
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/cpu
        value: "1"
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: "1Gi"

images:
  - name: ghcr.io/rafafuentes4/notafilia
    newTag: v1.0.0  # Pinned tag, manually promoted
```

### 1.5 Infrastructure: ArgoCD Application Manifests

These tell ArgoCD how to deploy third-party services using Helm charts.

#### `infrastructure/traefik/application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://traefik.github.io/charts
    targetRevision: "34.*"  # Latest 34.x (Traefik v3.x)
    chart: traefik
    helm:
      values: |
        # Enable Gateway API support
        providers:
          kubernetesGateway:
            enabled: true

        # Create a Gateway resource
        gateway:
          enabled: true
          name: traefik-gateway
          listeners:
            - name: web
              protocol: HTTP
              port: 80
            - name: websecure
              protocol: HTTPS
              port: 443
              tls:
                mode: Terminate
                certificateRefs:
                  - name: notafilia-tls  # Managed by cert-manager

        # Enable the Traefik dashboard (useful for learning)
        ingressRoute:
          dashboard:
            enabled: true

        # Resource requests
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 300m
            memory: 256Mi

        # Service type: LoadBalancer gets an external IP from OVH
        service:
          type: LoadBalancer
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Why `34.*` for targetRevision:** Traefik Helm chart v34.x corresponds to Traefik v3.x which has full Gateway API v1.4 conformance. Using a wildcard picks up patch releases automatically.

#### `infrastructure/cert-manager/application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    targetRevision: "v1.*"
    chart: cert-manager
    helm:
      values: |
        crds:
          enabled: true  # Install CRDs via Helm (simplest approach)

        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

After cert-manager is running, you also need a `ClusterIssuer` for Let's Encrypt. Create this in the infrastructure directory:

#### `infrastructure/cert-manager/cluster-issuer.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: rafafcantero@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: traefik-gateway
                namespace: traefik
```

**Note:** cert-manager supports Gateway API HTTP-01 solvers natively. This creates temporary HTTPRoutes for ACME challenges.

#### `infrastructure/cloudnative-pg/application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudnative-pg-operator
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://cloudnative-pg.github.io/charts
    targetRevision: "0.*"
    chart: cloudnative-pg
    helm:
      values: |
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

#### `infrastructure/cloudnative-pg/cluster-staging.yaml`

This is a CloudNativePG `Cluster` custom resource that declares a PostgreSQL instance:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: notafilia-pg
  namespace: staging
spec:
  instances: 1  # Single instance for staging (no HA needed)

  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: "128MB"

  bootstrap:
    initdb:
      database: notafilia
      owner: notafilia

  storage:
    size: 10Gi
    # OVH storage class — verify with: kubectl get storageclass
    # Common OVH classes: csi-cinder-high-speed, csi-cinder-classic
    # If neither exists, omit storageClass to use the cluster default
    storageClass: csi-cinder-high-speed

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

**How it works:** CloudNativePG creates:
- A Pod running PostgreSQL 17 (default)
- A PVC for data storage
- A Service `notafilia-pg-rw` for read-write connections
- A Secret `notafilia-pg-app` with auto-generated credentials

**The DATABASE_URL** in the app's secrets should reference `notafilia-pg-rw.<namespace>:5432`. CloudNativePG auto-generates credentials in a Secret named `notafilia-pg-app` — you can reference these directly or set your own password.

#### `infrastructure/cloudnative-pg/cluster-production.yaml`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: notafilia-pg
  namespace: production
spec:
  instances: 2  # Primary + 1 standby for HA in production

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"

  bootstrap:
    initdb:
      database: notafilia
      owner: notafilia

  storage:
    size: 20Gi
    storageClass: csi-cinder-high-speed  # Verify with kubectl get storageclass

  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: "1Gi"

  # Optional: backup to S3 (configure when needed)
  # backup:
  #   barmanObjectStore:
  #     destinationPath: s3://notafilia-pg-backups/production
  #     s3Credentials:
  #       accessKeyId:
  #         name: pg-backup-creds
  #         key: ACCESS_KEY_ID
  #       secretAccessKey:
  #         name: pg-backup-creds
  #         key: SECRET_ACCESS_KEY
```

#### `infrastructure/redis/application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redis
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.bitnami.com/bitnami
    targetRevision: "20.*"
    chart: redis
    helm:
      values: |
        # Standalone mode (no replicas)
        architecture: standalone

        auth:
          enabled: false  # Simpler for internal-only access

        master:
          persistence:
            enabled: true
            size: 2Gi
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: staging  # Deploy per-namespace; create separate App for production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Note:** You'll need a separate Application for production Redis (same config, different namespace). Alternatively, use an ApplicationSet to generate both.

### 1.6 ArgoCD App-of-Apps

The app-of-apps pattern uses one root ArgoCD Application that manages all other Applications.

#### `argocd/app-of-apps.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notafilia-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/RafaFuentes4/notafilia-infra.git
    targetRevision: main
    path: argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### `argocd/staging.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notafilia-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/RafaFuentes4/notafilia-infra.git
    targetRevision: main
    path: overlays/staging
    plugin:
      name: kustomize-sops  # Requires SOPS plugin configured in ArgoCD
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

#### `argocd/production.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notafilia-production
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/RafaFuentes4/notafilia-infra.git
    targetRevision: main
    path: overlays/production
    plugin:
      name: kustomize-sops
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: false      # Don't auto-delete production resources
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Note:** Production has `prune: false` as a safety measure — ArgoCD won't automatically delete resources that are removed from Git. This prevents accidental data loss.

#### `argocd/infrastructure.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notafilia-infrastructure
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/RafaFuentes4/notafilia-infra.git
    targetRevision: main
    path: infrastructure
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 1.7 SOPS Configuration

#### `.sops.yaml`

```yaml
creation_rules:
  # Staging secrets
  - path_regex: overlays/staging/.*\.enc\.yaml$
    age: >-
      age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    # Replace with your actual age public key

  # Production secrets
  - path_regex: overlays/production/.*\.enc\.yaml$
    age: >-
      age1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
    # Can use same or different key for production
```

### 1.8 Verification

```bash
# Verify staging overlay renders correctly
cd /Users/rafa/Developer/notafilia-infra
kubectl kustomize overlays/staging

# Verify production overlay renders correctly
kubectl kustomize overlays/production

# Check for YAML syntax errors
kubectl kustomize overlays/staging | kubectl apply --dry-run=client -f -
```

**What to check:**
- All resources have the correct namespace
- Image tags are correctly overridden
- ConfigMap values match the expected environment
- Secrets reference exists (won't have real values until SOPS encryption)

---

## Phase 2: OVH Cluster Setup

### Goal
Get a running Kubernetes cluster on OVH with `kubectl` access.

### 2.1 Create OVH Managed Kubernetes Cluster

1. Go to OVH Manager → Public Cloud → Managed Kubernetes
2. Create a new cluster:
   - **Region:** Choose closest to your users (e.g., GRA for France)
   - **Version:** Latest stable (1.30+)
   - **Node pool:** 1 pool, `b3-8` flavor (8GB RAM, 4 vCPU) — sufficient for staging + production on a single cluster
   - **Nodes:** 2-3 nodes (gives enough room for all services)
   - **Auto-scaling:** Optional, but recommended (min: 2, max: 4)

3. Wait for cluster to be ready (~5-10 minutes)

### 2.2 Configure kubectl

```bash
# Download kubeconfig from OVH Manager
# Place it in the default location or set KUBECONFIG
export KUBECONFIG=~/.kube/notafilia-ovh.yaml

# Verify connectivity
kubectl get nodes
kubectl cluster-info
```

### 2.3 Create Namespaces

```bash
kubectl create namespace staging
kubectl create namespace production
```

### 2.4 Install CLI Tools

```bash
# macOS with Homebrew
brew install argocd       # ArgoCD CLI
brew install helm         # Helm (for local testing)
brew install sops         # SOPS for secret encryption
brew install age          # age for encryption keys
brew install kustomize    # Standalone kustomize (optional, kubectl has it built-in)
```

### 2.5 Generate age Keys

```bash
# Generate a keypair
age-keygen -o ~/.config/sops/age/keys.txt

# The output shows the public key:
# Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Update .sops.yaml with the public key
```

**Important:** Back up `~/.config/sops/age/keys.txt` securely (e.g., password manager, encrypted cloud storage). This is the private key that decrypts all secrets. If lost, you'll need to re-encrypt everything with a new key.

### 2.6 Verification

```bash
kubectl get nodes                    # Should show 2-3 Ready nodes
kubectl get namespaces               # Should show staging, production, default, kube-system
kubectl get storageclass             # Note the available classes — update CloudNativePG
                                     # cluster manifests if csi-cinder-high-speed doesn't exist
argocd version --client              # Should show CLI version
sops --version                       # Should show SOPS version
age --version                        # Should show age version
```

---

## Phase 3: ArgoCD + Infrastructure Services

### Goal
Install ArgoCD, configure SOPS decryption, and deploy all infrastructure services (Traefik, cert-manager, CloudNativePG, Redis) via the app-of-apps pattern.

### 3.1 Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s

# Get the initial admin password
argocd admin initial-password -n argocd

# Port-forward to access the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` → login with `admin` and the initial password.

### 3.2 Configure ArgoCD for SOPS

ArgoCD needs the age private key to decrypt SOPS-encrypted secrets during sync.

**Option A: KSOPS plugin (recommended)**

Install KSOPS (Kustomize + SOPS integration):

```bash
# Create a ConfigMap with the KSOPS plugin config
kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmp-cm
  namespace: argocd
data:
  kustomize-sops.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: kustomize-sops
    spec:
      generate:
        command: ["sh", "-c"]
        args: ["kustomize build . | sops --decrypt /dev/stdin"]
      discover:
        find:
          glob: "**/kustomization.yaml"
EOF
```

Create the age key as a K8s Secret:

```bash
# Create secret from your age key file
kubectl create secret generic age-key \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt \
  -n argocd

# Patch the argocd-repo-server to mount the age key
kubectl patch deployment argocd-repo-server -n argocd --type json -p '[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "age-key",
      "secret": {
        "secretName": "age-key"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "age-key",
      "mountPath": "/home/argocd/.config/sops/age"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "SOPS_AGE_KEY_FILE",
      "value": "/home/argocd/.config/sops/age/keys.txt"
    }
  }
]'
```

**Important notes:**
- The KSOPS generate command does NOT have a fallback — if SOPS decryption fails, the sync fails. This is intentional: silently deploying unencrypted secrets would be a security risk.
- There are multiple approaches to integrate SOPS with ArgoCD (KSOPS plugin, argocd-vault-plugin, Helm secrets plugin). The exact setup may need adjustment based on the ArgoCD version. Check the ArgoCD docs for the latest recommended approach.
- After patching, restart the repo-server: `kubectl rollout restart deployment argocd-repo-server -n argocd`

### 3.3 Connect the Git Repository

```bash
# Login to ArgoCD CLI
argocd login localhost:8080 --username admin --password <password> --insecure

# Add the Git repository
argocd repo add https://github.com/RafaFuentes4/notafilia-infra.git \
  --username RafaFuentes4 \
  --password <github-pat>  # Or use SSH key
```

### 3.4 Deploy the App-of-Apps

```bash
# Apply the root Application
kubectl apply -f argocd/app-of-apps.yaml

# ArgoCD now auto-discovers and deploys:
# 1. infrastructure.yaml → Traefik, cert-manager, CloudNativePG, Redis
# 2. staging.yaml → Staging overlay
# 3. production.yaml → Production overlay (will fail until secrets exist)
```

### 3.5 Install Gateway API CRDs

Gateway API CRDs need to be installed separately (Traefik doesn't install them):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### 3.6 Verification

Open the ArgoCD UI at `https://localhost:8080`. You should see:

- `notafilia-root` — Synced, Healthy
- `notafilia-infrastructure` — Synced, Healthy (deploys all infra Applications)
- `traefik` — Synced, Healthy
- `cert-manager` — Synced, Healthy
- `cloudnative-pg-operator` — Synced, Healthy
- `redis` — Synced, Healthy

```bash
# Verify infrastructure pods
kubectl get pods -n traefik
kubectl get pods -n cert-manager
kubectl get pods -n cnpg-system
kubectl get pods -n staging  # Should show Redis + PostgreSQL pods

# Verify Traefik got an external IP
kubectl get svc -n traefik traefik
# EXTERNAL-IP should show an OVH public IP

# Verify CloudNativePG cluster
kubectl get clusters.postgresql.cnpg.io -n staging
# STATUS should be "Cluster in healthy state"

# Verify Gateway
kubectl get gateways -n traefik
```

---

## Phase 4: App Deployment (Staging)

### Goal
Encrypt secrets with SOPS and deploy the Notafilia app to the staging namespace.

### 4.1 Encrypt Staging Secrets

```bash
cd /Users/rafa/Developer/notafilia-infra

# First, fill in the real values in overlays/staging/secrets.enc.yaml
# (this file should contain the plaintext Secret YAML)

# Encrypt with SOPS (uses .sops.yaml rules automatically)
sops -e -i overlays/staging/secrets.enc.yaml

# Verify: the file should now have encrypted values but readable keys
cat overlays/staging/secrets.enc.yaml
# stringData:
#   SECRET_KEY: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
#   DATABASE_URL: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
```

### 4.2 Get Database Credentials

CloudNativePG auto-generates credentials. Retrieve them:

```bash
# Get the auto-generated password
kubectl get secret notafilia-pg-app -n staging -o jsonpath='{.data.password}' | base64 -d

# Use this to construct DATABASE_URL:
# postgresql://notafilia:<password>@notafilia-pg-rw.staging:5432/notafilia
```

Update the `DATABASE_URL` in your secrets file, re-encrypt with SOPS, commit, and push.

### 4.3 Build and Push Initial Docker Image

Before the app can deploy, you need an image in GHCR:

```bash
cd /Users/rafa/Developer/notafilia

# Build the Docker image
docker build -f Dockerfile.web -t ghcr.io/rafafuentes4/notafilia:staging-latest .

# Login to GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u RafaFuentes4 --password-stdin

# Push
docker push ghcr.io/rafafuentes4/notafilia:staging-latest
```

### 4.4 Push and Sync

```bash
cd /Users/rafa/Developer/notafilia-infra
git add -A
git commit -m "Add staging secrets and initial configuration"
git push

# ArgoCD auto-syncs (if syncPolicy.automated is configured)
# Or manually:
argocd app sync notafilia-staging
```

### 4.5 Configure DNS

Point `staging.notafilia.com` to the Traefik LoadBalancer IP:

```bash
# Get the external IP
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Add A record: staging.notafilia.com → <external-ip>
# (Do this in your DNS provider's dashboard)
```

### 4.6 Verification

```bash
# Check pods are running
kubectl get pods -n staging
# Should show: notafilia-web-xxx, notafilia-celery-xxx, notafilia-beat-xxx

# Check init container (migrations) completed
kubectl describe pod -n staging -l app.kubernetes.io/component=web
# Init container "migrate" should show "Completed"

# Check logs
kubectl logs -n staging -l app.kubernetes.io/component=web -c web
kubectl logs -n staging -l app.kubernetes.io/component=celery

# Test the endpoint
curl -v https://staging.notafilia.com

# Check TLS certificate
curl -vI https://staging.notafilia.com 2>&1 | grep "subject:"
```

In the ArgoCD UI, `notafilia-staging` should show all resources Synced and Healthy.

---

## Phase 5: CI/CD (GitHub Actions)

### Goal
Automate Docker image builds on push to `main` and trigger ArgoCD sync.

### 5.1 GitHub Actions Workflow

Create `.github/workflows/build-and-push.yml` in the **notafilia** app repo:

```yaml
name: Build and Push Docker Image

on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write  # Required for GHCR push

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}  # Automatic OIDC, no stored secrets

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile.web
          push: true
          tags: |
            ghcr.io/rafafuentes4/notafilia:${{ github.sha }}
            ghcr.io/rafafuentes4/notafilia:staging-latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Key decisions:**
- **Tags:** Every build gets a SHA tag (immutable) and `staging-latest` (mutable, for staging auto-deploy).
- **Cache:** Uses GitHub Actions cache for Docker layers — dramatically speeds up builds since Python deps and npm packages rarely change.
- **OIDC:** `${{ secrets.GITHUB_TOKEN }}` is automatically available — no need to store registry credentials.

### 5.2 ArgoCD Image Updater (Optional)

For automatic staging deployment when new images are pushed:

```bash
# Install ArgoCD Image Updater
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

Add annotations to the staging Application:

```yaml
# In argocd/staging.yaml, add annotations:
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: notafilia=ghcr.io/rafafuentes4/notafilia
    argocd-image-updater.argoproj.io/notafilia.update-strategy: latest
    argocd-image-updater.argoproj.io/notafilia.allow-tags: "regexp:^staging-"
```

**Alternative (simpler):** Skip Image Updater. Instead, add a step to the GitHub Actions workflow that updates the image tag in `notafilia-infra` via a commit:

```yaml
      - name: Update staging image tag
        run: |
          git clone https://x-access-token:${{ secrets.INFRA_REPO_PAT }}@github.com/RafaFuentes4/notafilia-infra.git
          cd notafilia-infra
          # Update the image tag in the staging overlay
          cd overlays/staging
          kustomize edit set image ghcr.io/rafafuentes4/notafilia:${{ github.sha }}
          git add .
          git commit -m "Update staging image to ${{ github.sha }}"
          git push
```

### 5.3 Production Promotion

Production uses pinned tags. To promote a staging build to production:

```bash
cd /Users/rafa/Developer/notafilia-infra

# Update production image tag
cd overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:v1.0.1

# Tag the image for clarity
cd /Users/rafa/Developer/notafilia
docker pull ghcr.io/rafafuentes4/notafilia:<sha-from-staging>
docker tag ghcr.io/rafafuentes4/notafilia:<sha-from-staging> ghcr.io/rafafuentes4/notafilia:v1.0.1
docker push ghcr.io/rafafuentes4/notafilia:v1.0.1

# Commit and push
cd /Users/rafa/Developer/notafilia-infra
git add .
git commit -m "Promote v1.0.1 to production"
git push
```

### 5.4 Verification

```bash
# Push a change to notafilia main branch
# Watch GitHub Actions: https://github.com/RafaFuentes4/notafilia/actions

# After workflow completes, check ArgoCD:
argocd app get notafilia-staging
# Should show "OutOfSync" → "Synced" within a few minutes

# Verify the new image is running
kubectl get pods -n staging -o jsonpath='{.items[*].spec.containers[*].image}'
```

---

## Phase 6: Production

### Goal
Deploy to production with proper TLS, DNS, and safety measures.

### 6.1 Encrypt Production Secrets

```bash
cd /Users/rafa/Developer/notafilia-infra

# Fill in production values in overlays/production/secrets.enc.yaml
# IMPORTANT: Use different credentials than staging!

# Get production PostgreSQL credentials
kubectl get secret notafilia-pg-app -n production -o jsonpath='{.data.password}' | base64 -d

# Encrypt
sops -e -i overlays/production/secrets.enc.yaml
```

### 6.2 Configure Production DNS

Point `notafilia.com` to the Traefik LoadBalancer IP:

```bash
# Get the external IP (same one used for staging)
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Add DNS records:
# A record: notafilia.com → <external-ip>
# A record: www.notafilia.com → <external-ip> (optional)
```

### 6.3 Request TLS Certificate

Create a Certificate resource (or let cert-manager auto-create via Gateway API annotations):

```yaml
# infrastructure/cert-manager/certificate-production.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: notafilia-tls
  namespace: production
spec:
  secretName: notafilia-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - notafilia.com
    - www.notafilia.com
```

### 6.4 Push and Sync

```bash
git add -A
git commit -m "Add production configuration"
git push

# Monitor in ArgoCD UI
argocd app sync notafilia-production
```

### 6.5 Post-Deployment Checklist

```bash
# Verify all pods running
kubectl get pods -n production

# Verify TLS certificate
kubectl get certificate -n production
# READY should be True

# Test the app
curl -vI https://notafilia.com

# Check production logs for errors
kubectl logs -n production -l app.kubernetes.io/component=web -c web --tail=50

# Verify Celery is processing tasks
kubectl logs -n production -l app.kubernetes.io/component=celery --tail=20

# Verify Beat is scheduling tasks
kubectl logs -n production -l app.kubernetes.io/component=beat --tail=20
```

### 6.6 Production Safety Measures

Things to configure after initial deployment:

1. **Pod Disruption Budgets** — Ensure at least 1 web pod is always running during node maintenance:
   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: notafilia-web-pdb
     namespace: production
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         app.kubernetes.io/component: web
   ```

2. **Resource monitoring** — Check actual resource usage after a few days:
   ```bash
   kubectl top pods -n production
   ```

3. **CloudNativePG backups** — Uncomment the backup section in `cluster-production.yaml` and configure S3 credentials.

4. **ArgoCD notifications** — Configure Slack/email notifications for sync failures.

---

## Appendix: Complete File List

| Path | Type | Phase |
|------|------|-------|
| `base/kustomization.yaml` | Kustomize base | 1 |
| `base/deployment-web.yaml` | Deployment | 1 |
| `base/deployment-celery.yaml` | Deployment | 1 |
| `base/deployment-beat.yaml` | Deployment | 1 |
| `base/service-web.yaml` | Service | 1 |
| `base/configmap.yaml` | ConfigMap | 1 |
| `base/httproute.yaml` | Gateway API HTTPRoute | 1 |
| `overlays/staging/kustomization.yaml` | Staging overlay | 1 |
| `overlays/staging/secrets.enc.yaml` | SOPS-encrypted secrets | 4 |
| `overlays/production/kustomization.yaml` | Production overlay | 1 |
| `overlays/production/secrets.enc.yaml` | SOPS-encrypted secrets | 6 |
| `infrastructure/traefik/application.yaml` | ArgoCD App | 1 |
| `infrastructure/cert-manager/application.yaml` | ArgoCD App | 1 |
| `infrastructure/cert-manager/cluster-issuer.yaml` | ClusterIssuer | 1 |
| `infrastructure/cloudnative-pg/application.yaml` | ArgoCD App | 1 |
| `infrastructure/cloudnative-pg/cluster-staging.yaml` | PG Cluster CR | 1 |
| `infrastructure/cloudnative-pg/cluster-production.yaml` | PG Cluster CR | 1 |
| `infrastructure/redis/application.yaml` | ArgoCD App | 1 |
| `argocd/app-of-apps.yaml` | Root Application | 1 |
| `argocd/staging.yaml` | Staging Application | 1 |
| `argocd/production.yaml` | Production Application | 1 |
| `argocd/infrastructure.yaml` | Infrastructure Application | 1 |
| `.sops.yaml` | SOPS config | 1 |
| `.github/workflows/build-and-push.yml` | CI/CD (in app repo) | 5 |

**Total: ~24 files** across both repos.
