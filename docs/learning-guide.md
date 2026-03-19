# Notafilia K8s Infrastructure — Learning Guide

This guide explains every Kubernetes concept used in this project, with real examples from our actual deployment. It's written for a developer who knows Django but is new to Kubernetes.

---

## The Big Picture

### What problem does Kubernetes solve?

Without K8s, you deploy by SSH-ing into a server, pulling your Docker image, and running it. If the server dies, your app is down. If you need more capacity, you manually spin up another server.

Kubernetes automates all of this: you describe *what you want* (3 copies of my app, a database, a load balancer) and K8s makes it happen. If a server dies, K8s moves your app to another server. If you need more capacity, you change a number in a YAML file.

### What we built

```
You push code → GitHub Actions builds a Docker image → pushes to GHCR
                                                           ↓
ArgoCD watches the Git repo → detects changes → syncs to the cluster
                                                           ↓
OVH Kubernetes runs: Traefik (routing) → Django (web) + Celery + PostgreSQL + Redis
                                                           ↓
Users access: https://notafilia.es (production) / https://staging.notafilia.es (staging)
```

### Our actual cluster

```
OVH Managed K8s (Gravelines, France)
├── 2 nodes (B3-8: 8GB RAM, 2 vCPU each)
├── 22 pods total across 6 namespaces
├── External IP: 57.128.58.136
└── TLS: Let's Encrypt auto-renewed certificates
```

---

## Core Concepts (with our examples)

### 1. Pods

A Pod is the smallest thing K8s runs. It's one or more containers sharing the same network.

**Our example**: `notafilia-web-74cb999499-8nb52` is a Pod. It contains one container running Gunicorn.

```bash
# See all pods in staging
kubectl get pods -n staging

# See details about a pod
kubectl describe pod notafilia-web-74cb999499-8nb52 -n staging

# View logs from a pod
kubectl logs notafilia-web-74cb999499-8nb52 -n staging -c web
```

You almost never create Pods directly — you create Deployments (see below) which manage Pods for you.

### 2. Deployments

A Deployment tells K8s: "I want N copies of this Pod, and if any die, recreate them."

**Our example** (`base/deployment-web.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notafilia-web
spec:
  replicas: 1                    # How many copies
  selector:
    matchLabels:
      app.kubernetes.io/component: web   # "Manage pods with this label"
  template:                      # Pod template
    spec:
      initContainers:
        - name: migrate          # Runs BEFORE the main container
          command: ["python", "manage.py", "migrate", "--noinput"]
      containers:
        - name: web              # The main container
          image: ghcr.io/rafafuentes4/notafilia:staging-latest
          command: ["gunicorn", "--bind=0.0.0.0:8000", ...]
```

**Key concepts:**
- `replicas: 1` → K8s always keeps 1 pod running. Kill it, K8s starts another.
- `initContainers` → Run before the main container. We use this for `manage.py migrate`. If migrations fail, the pod stays in `Init:Error` and Gunicorn never starts (which is what you want).
- `image` → The Docker image to run. This is overridden per environment by Kustomize overlays.

**Our Celery Beat Deployment** has a special `strategy: Recreate`:
```yaml
spec:
  replicas: 1
  strategy:
    type: Recreate    # Kill old pod BEFORE starting new one
```
Why? Beat schedules tasks. If two Beat instances run simultaneously, you get duplicate tasks. `Recreate` ensures zero overlap during deployments.

### 3. Services

Pods get random IP addresses that change when they restart. A Service gives them a stable address.

**Our example** (`base/service-web.yaml`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: notafilia-web
spec:
  type: ClusterIP       # Only accessible inside the cluster
  ports:
    - port: 8000
  selector:
    app.kubernetes.io/component: web   # "Route to pods with this label"
```

Now anything in the cluster can reach our Django app at `notafilia-web:8000` — regardless of which pod is running or what its IP is.

**Service types we use:**
- **ClusterIP** (default) — Internal only. Used for web, Redis, PostgreSQL.
- **LoadBalancer** — Gets a public IP from OVH. Used only for Traefik (`57.128.58.136`).

### 4. Namespaces

Namespaces are like folders for K8s resources. They provide isolation.

**Our namespaces:**
| Namespace | What's in it |
|-----------|-------------|
| `staging` | Django app + Celery + Beat + PostgreSQL + Redis (staging env) |
| `production` | Same thing (production env) |
| `argocd` | ArgoCD itself |
| `traefik` | Traefik proxy + TLS certificates |
| `cert-manager` | cert-manager controller |
| `cnpg-system` | CloudNativePG operator |

Staging and production are completely isolated. Different databases, different secrets, different pods. Same manifests, different overlays.

### 5. ConfigMaps and Secrets

How you pass configuration to containers — the K8s equivalent of `.env` files.

**ConfigMap** — Non-sensitive values (`base/configmap.yaml`):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: notafilia-config
data:
  DJANGO_SETTINGS_MODULE: "notafilia.settings_production"
  ALLOWED_HOSTS: "*"           # Overridden per environment
  USE_S3_MEDIA: "True"
```

**Secret** — Sensitive values (created via `kubectl apply`, not in Git):
```yaml
stringData:
  SECRET_KEY: "l1TrB1Uo3J-..."
  DATABASE_URL: "postgresql://notafilia:<password>@notafilia-pg-rw.staging:5432/notafilia"
  REDIS_URL: "redis://redis-master.staging:6379/0"
```

**How pods consume them** (in the Deployment):
```yaml
envFrom:
  - configMapRef:
      name: notafilia-config     # All keys become env vars
  - secretRef:
      name: notafilia-secrets    # All keys become env vars
```

This means inside the pod, Django sees `os.environ["DATABASE_URL"]` exactly like it would with a `.env` file.

### 6. Persistent Volumes (PVCs)

Containers are ephemeral — when a pod dies, its filesystem is gone. PVCs give pods durable storage.

**Our example** (Redis):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
  storageClassName: csi-cinder-high-speed   # OVH's fast SSD storage
```

OVH automatically provisions a 2GB SSD volume and attaches it to the pod. If the pod restarts, the data is still there.

**Our PVCs:**
- PostgreSQL staging: 10Gi
- PostgreSQL production: 20Gi
- Redis staging/production: 2Gi each

---

## How Kustomize Works (with our code)

Kustomize is our "template" system, but it doesn't use templates. Instead:

1. **Base** (`base/`) — The full app manifests with generic values
2. **Overlays** (`overlays/staging/`, `overlays/production/`) — Patches that modify the base

### Base → Overlay → Final YAML

**Base** (`base/configmap.yaml`):
```yaml
data:
  ALLOWED_HOSTS: "*"    # Generic placeholder
```

**Staging overlay** (`overlays/staging/kustomization.yaml`):
```yaml
patches:
  - target:
      kind: ConfigMap
      name: notafilia-config
    patch: |-
      - op: replace
        path: /data/ALLOWED_HOSTS
        value: "staging.notafilia.es"   # Staging-specific
```

**Result** (what K8s actually sees):
```yaml
data:
  ALLOWED_HOSTS: "staging.notafilia.es"
```

### Image tag overrides

The base uses `ghcr.io/rafafuentes4/notafilia:latest`. The overlay changes the tag:

```yaml
images:
  - name: ghcr.io/rafafuentes4/notafilia
    newTag: staging-latest    # Or v1.0.0 for production
```

Kustomize finds every reference to that image and replaces the tag. No editing deployment files.

### Try it yourself

```bash
# See what staging actually produces:
kubectl kustomize overlays/staging/

# Compare with production:
kubectl kustomize overlays/production/
```

---

## How ArgoCD Works (GitOps)

### The concept

Traditional deployment: you run `kubectl apply` manually. If someone changes something on the cluster directly, your Git repo and the cluster diverge.

GitOps: the Git repo is the **single source of truth**. ArgoCD watches the repo and continuously makes the cluster match what's in Git. If someone manually edits something on the cluster, ArgoCD reverts it.

### App-of-apps pattern

We use one root Application that bootstraps everything:

```
notafilia-root (watches argocd/ directory)
├── notafilia-infrastructure (watches infrastructure/ recursively)
│   ├── traefik (Helm chart → Traefik pod + LoadBalancer)
│   ├── cert-manager (Helm chart → cert-manager + CRDs)
│   ├── cloudnative-pg-operator (Helm chart → CNPG operator)
│   ├── ClusterIssuer (Let's Encrypt config)
│   ├── Certificate (TLS cert for our domains)
│   ├── PG Cluster staging (PostgreSQL instance)
│   ├── PG Cluster production (PostgreSQL instance)
│   ├── Redis staging (Deployment + PVC + Service)
│   └── Redis production (Deployment + PVC + Service)
├── notafilia-staging (watches overlays/staging → app pods)
└── notafilia-production (watches overlays/production → app pods)
```

**One `kubectl apply` deploys everything.** Push a change to Git and ArgoCD syncs it within 3 minutes.

### Sync waves

Some things must deploy before others. CloudNativePG Clusters need the CNPG operator installed first. We use annotations:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"    # Deploy after wave 0 (default)
```

Wave 0 (operators) deploys first → Wave 1 (CRD instances) deploys second.

---

## How Gateway API + Traefik Works

### The old way: Ingress (deprecated)

```yaml
# DON'T USE THIS — Ingress API is feature-frozen, ingress-nginx is EOL
apiVersion: networking.k8s.io/v1
kind: Ingress
```

### The new way: Gateway API

Three resources work together:

**GatewayClass** → "Who handles traffic?" (Traefik — configured by the Helm chart)

**Gateway** → "Where to listen?" (ports 80/443, with TLS)
- Our Gateway is in the `traefik` namespace
- `namespacePolicy: All` allows routes from other namespaces

**HTTPRoute** → "Where to send traffic?" (`base/httproute.yaml`):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: notafilia
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik           # Gateway is in traefik namespace
  hostnames:
    - "notafilia.example.com"      # Overridden by overlay to notafilia.es
  rules:
    - backendRefs:
        - name: notafilia-web      # Send to our Service
          port: 8000
```

**The full flow:**
```
Browser → notafilia.es:443
  → DNS resolves to 57.128.58.136 (OVH LoadBalancer)
    → Traefik receives the request
      → Checks HTTPRoutes: "notafilia.es" matches production route
        → Forwards to notafilia-web Service in production namespace
          → Reaches a Gunicorn pod
```

---

## How TLS/HTTPS Works

### The components

1. **cert-manager** — A K8s operator that automates certificate management
2. **ClusterIssuer** — Tells cert-manager to use Let's Encrypt
3. **Certificate** — "I want a cert for notafilia.es and staging.notafilia.es"

### What happens automatically

1. cert-manager sees the Certificate resource
2. Contacts Let's Encrypt: "I want a cert for notafilia.es"
3. Let's Encrypt says: "Prove you own that domain. Serve this token at `http://notafilia.es/.well-known/acme-challenge/xxx`"
4. cert-manager creates a temporary HTTPRoute via Gateway API
5. Traefik serves the token
6. Let's Encrypt verifies → issues the certificate
7. cert-manager stores it as a K8s Secret (`notafilia-tls`) in the `traefik` namespace
8. Traefik uses this Secret for HTTPS
9. cert-manager auto-renews before expiry

You never manually create or renew certificates. It's fully automated.

---

## How CloudNativePG Works

### Why not just run PostgreSQL in a regular Deployment?

Databases need special care: persistent storage, backup/restore, failover, connection management. A regular Deployment doesn't handle any of this.

CloudNativePG is an **operator** — a program that understands how to run PostgreSQL properly on Kubernetes.

### What you declare

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster                        # Custom resource (not a standard K8s resource)
metadata:
  name: notafilia-pg
  namespace: staging
spec:
  instances: 1                       # Number of PostgreSQL instances
  bootstrap:
    initdb:
      database: notafilia            # Auto-create this database
      owner: notafilia               # Auto-create this user
  storage:
    size: 10Gi
```

### What the operator creates automatically

From that single YAML, CloudNativePG creates:
- **Pod** `notafilia-pg-1` running PostgreSQL 18
- **PVC** `notafilia-pg-1` with 10Gi storage
- **Service** `notafilia-pg-rw` (read-write endpoint — this is what your `DATABASE_URL` points to)
- **Service** `notafilia-pg-r` (read replicas, for future use)
- **Secret** `notafilia-pg-app` (auto-generated username/password)

Your app connects to `postgresql://notafilia:<auto-password>@notafilia-pg-rw.staging:5432/notafilia`. The password is in the auto-generated Secret.

---

## How SOPS + age Works

### The problem

Secrets (database passwords, API keys) need to be in Git for GitOps to work, but you can't store plaintext secrets in Git.

### The solution

**SOPS** encrypts individual values in YAML files. **age** is the encryption algorithm.

```yaml
# Before encryption:
stringData:
  SECRET_KEY: "my-real-secret"
  DATABASE_URL: "postgresql://..."

# After `sops -e -i secrets.enc.yaml`:
stringData:
  SECRET_KEY: ENC[AES256_GCM,data:xxxx,type:str]
  DATABASE_URL: ENC[AES256_GCM,data:yyyy,type:str]
```

The keys are readable, only values are encrypted. This means `git diff` shows you *which* secrets changed without revealing the values.

### Key management

```bash
# Generate a keypair (once)
age-keygen -o ~/.config/sops/age/keys.txt
# Public key: age1xxx... (goes in .sops.yaml, safe to commit)
# Private key: AGE-SECRET-KEY-xxx... (NEVER commit, back up to 1Password)
```

`.sops.yaml` tells SOPS which key to use for which files:
```yaml
creation_rules:
  - path_regex: overlays/staging/.*\.enc\.yaml$
    age: age1gg0wxkdew42q0glwhp4efy83cna825stw9l8n6merxr2znm8t4esvak57u
```

---

## How CI/CD Works

### The pipeline

```
Developer pushes to main
  → GitHub Actions triggers
    → Builds Docker image (linux/amd64) from Dockerfile.web
      → Pushes to GHCR with tags: {sha} + staging-latest
        → kubectl rollout restart picks up the new image
```

**Workflow file** (`.github/workflows/build-and-push.yml`):
- Uses `docker/build-push-action` with BuildKit
- `platforms: linux/amd64` — critical because OVH nodes are x86 but dev machines are ARM
- `cache-from: type=gha` — caches Docker layers in GitHub's cache (fast rebuilds)
- `${{ secrets.GITHUB_TOKEN }}` — automatic OIDC token, no stored secrets needed

### Production promotion

Staging gets `staging-latest` automatically. Production uses pinned tags:

```bash
# Tag the current staging image as v1.1.0
docker tag ghcr.io/rafafuentes4/notafilia:staging-latest ghcr.io/rafafuentes4/notafilia:v1.1.0
docker push ghcr.io/rafafuentes4/notafilia:v1.1.0

# Update production overlay and push to Git
cd overlays/production
kustomize edit set image ghcr.io/rafafuentes4/notafilia:v1.1.0
git commit -am "Promote v1.1.0" && git push
# ArgoCD picks it up → production updated
```

---

## How Health Checks Work

K8s needs to know if your app is alive and ready to serve traffic.

### Readiness probe

"Is this pod ready to receive traffic?"

```yaml
readinessProbe:
  httpGet:
    path: /up        # Django middleware endpoint
    port: http
  initialDelaySeconds: 10    # Wait 10s after start
  periodSeconds: 10          # Check every 10s
```

If the probe fails, K8s removes the pod from the Service's endpoints. Traefik stops sending traffic to it. Once it passes again, traffic resumes.

### Liveness probe

"Is this pod still alive, or is it stuck?"

```yaml
livenessProbe:
  httpGet:
    path: /up
    port: http
  initialDelaySeconds: 30    # Wait 30s before first check
  periodSeconds: 30
```

If the probe fails repeatedly, K8s kills and restarts the pod.

### Why `/up` instead of `/health/`

We use `/up` (a Django middleware endpoint) instead of `/health/` (the django-health-check endpoint) because:
- `/health/` goes through Django's full request pipeline, including `ALLOWED_HOSTS` validation
- K8s probes hit the pod via its internal IP (e.g., `10.2.0.139:8000`), which isn't in `ALLOWED_HOSTS`
- `/up` is handled by middleware *before* `ALLOWED_HOSTS` — it always returns "OK"

---

## Resource Requests and Limits

Every container declares how much CPU/memory it needs.

```yaml
resources:
  requests:          # Guaranteed minimum
    cpu: 25m         # 25 millicores = 2.5% of one CPU
    memory: 128Mi    # 128 megabytes
  limits:            # Maximum allowed
    cpu: 500m        # 50% of one CPU
    memory: 512Mi    # 512 megabytes
```

**Requests** = what the scheduler uses to place pods on nodes. If a node has 2 CPUs and your pods request 2.1 CPUs total, the scheduler can't fit them → `Insufficient cpu` error.

**Limits** = the ceiling. If a container exceeds memory limits, K8s kills it (OOMKilled). CPU is throttled, not killed.

**Our resource budget** (per environment):
| Component | CPU request | Memory request |
|-----------|-------------|----------------|
| Web | 25m | 128Mi |
| Celery | 25m | 128Mi |
| Beat | 10m | 64Mi |
| PostgreSQL | 50m | 256Mi |
| Redis | 50m | 64Mi |
| **Total per env** | **160m** | **640Mi** |

Two environments + infrastructure (ArgoCD, Traefik, cert-manager, CNPG operator) fit comfortably on 2× B3-8 nodes (4 CPUs, 16GB total).

---

## Debugging Commands

When something goes wrong, these commands tell you what's happening:

```bash
# What's running?
kubectl get pods -n staging

# Why won't my pod start?
kubectl describe pod <pod-name> -n staging
# Look at Events section at the bottom

# What are the logs?
kubectl logs <pod-name> -n staging -c web        # Main container
kubectl logs <pod-name> -n staging -c migrate     # Init container
kubectl logs <pod-name> -n staging --previous     # Previous crash

# What's inside the pod?
kubectl exec -it <pod-name> -n staging -c web -- bash
kubectl exec -it <pod-name> -n staging -c web -- env | grep DATABASE

# Is my service reachable?
kubectl run debug --image=busybox --rm -it --restart=Never -- \
  wget -qO- http://notafilia-web.staging:8000/up

# What resources exist?
kubectl get all -n staging

# What does ArgoCD think?
kubectl get applications -n argocd
argocd app get notafilia-staging --grpc-web

# Resource usage
kubectl top nodes
kubectl top pods -n staging
```

---

## Glossary

| Term | Meaning | Our example |
|------|---------|-------------|
| **Pod** | Smallest runnable unit (one or more containers) | `notafilia-web-74cb999499-8nb52` |
| **Deployment** | Manages Pods, ensures desired count runs | `notafilia-web` (1 replica) |
| **Service** | Stable network endpoint for Pods | `notafilia-web` (ClusterIP:8000) |
| **Namespace** | Isolation boundary | `staging`, `production` |
| **ConfigMap** | Non-secret configuration data | `notafilia-config` (DJANGO_SETTINGS_MODULE, etc.) |
| **Secret** | Sensitive configuration data | `notafilia-secrets` (DATABASE_URL, SECRET_KEY) |
| **PVC** | Persistent storage request | `redis-data` (2Gi SSD) |
| **CRD** | Custom Resource Definition — extends K8s API | `Cluster` (CloudNativePG), `Certificate` (cert-manager) |
| **Operator** | Controller that manages complex software via CRDs | CloudNativePG, cert-manager |
| **Gateway** | Network entry point (port listener + TLS) | `traefik-gateway` (ports 80/443) |
| **HTTPRoute** | Routes traffic from Gateway to Services | `notafilia` (host → notafilia-web:8000) |
| **Application** | ArgoCD resource that syncs Git → cluster | `notafilia-staging` |
| **Sync** | ArgoCD making cluster match Git | Automatic every ~3 minutes |
| **Self-heal** | ArgoCD reverting manual cluster changes | Enabled on all our apps |
| **Init container** | Runs before main container | `migrate` (runs Django migrations) |
| **LoadBalancer** | Service type that gets a public IP | Traefik (57.128.58.136) |
| **ClusterIP** | Service type only reachable inside cluster | notafilia-web, redis-master |
| **Sync wave** | ArgoCD ordering mechanism | Operators (wave 0) before CRD instances (wave 1) |
| **Kustomize overlay** | Environment-specific patches | `overlays/staging/` patches base for staging |
| **SOPS** | Encrypts secret values in YAML files | `secrets.enc.yaml` |
| **age** | Encryption algorithm used with SOPS | Public key in `.sops.yaml` |

---

## Recommended Reading

Start with these, in order:

1. [Understanding Kubernetes Objects](https://kubernetes.io/docs/concepts/overview/working-with-objects/) (15 min)
2. [Pods](https://kubernetes.io/docs/concepts/workloads/pods/) (10 min)
3. [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) (15 min)
4. [Services](https://kubernetes.io/docs/concepts/services-networking/service/) (10 min)
5. [Kustomize Tutorial](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) (20 min)
6. [Gateway API Introduction](https://gateway-api.sigs.k8s.io/) (15 min)
7. [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/) (30 min)
8. [CloudNativePG Quickstart](https://cloudnative-pg.io/documentation/current/quickstart/) (20 min)
9. [cert-manager Concepts](https://cert-manager.io/docs/concepts/) (15 min)
10. [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/) (bookmark this)

**Total: ~3 hours.** Most learning happens by doing — use these as references while working through the setup guide.
