# Notafilia K8s Infrastructure — Learning Guide

## How to Use This Guide

Each phase has a **"Learn Before"** section (concepts you should understand before starting) and a **"Learn During"** section (things that will click once you're doing the work). Links point to official documentation — these are the authoritative sources.

The goal is not to memorize everything upfront. Skim the "Learn Before" topics, start the phase, and refer back when you get stuck.

---

## Phase 1: Repository + Local Tooling

### Learn Before

#### Kubernetes Resource Model
Everything in K8s is a **resource** described by a YAML manifest. Every resource has `apiVersion`, `kind`, `metadata`, and `spec`. Understanding this pattern unlocks everything else.

- Read: [Understanding Kubernetes Objects](https://kubernetes.io/docs/concepts/overview/working-with-objects/)
- Read: [Kubernetes API Conventions](https://kubernetes.io/docs/reference/using-api/api-concepts/) (first 3 sections)

Key concepts:
- **Namespace** — A virtual cluster within a cluster. Resources in different namespaces are isolated. You'll use `staging` and `production` namespaces.
- **Labels and Selectors** — How K8s resources find each other. A Service finds its Pods via label selectors. A Deployment manages Pods via label selectors.
- **Declarative vs Imperative** — K8s is declarative: you describe the desired state, and K8s makes it happen. You never say "start 3 pods" — you say "I want 3 replicas" and K8s creates/destroys pods to match.

#### Kustomize
Kustomize lets you customize YAML without templates. You write plain K8s manifests (the "base"), then create "overlays" that patch specific values per environment.

- Read: [Kustomize Official Docs](https://kustomize.io/)
- Read: [Kustomize Built-in Transformers](https://kubectl.docs.kubernetes.io/references/kustomize/builtins/)
- Hands-on: [Kustomize Tutorial](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

Key concepts:
- **Base** — The default manifests. Contains everything the app needs, with placeholder values.
- **Overlay** — A directory that patches the base for a specific environment. Uses JSON patches or strategic merge patches.
- **`kustomization.yaml`** — The manifest that ties everything together. Lists resources, patches, and transformations.
- **`images` transformer** — Override image tags without editing the original YAML. This is how CI/CD updates the deployed version.

**Why Kustomize instead of Helm for your app:** Helm uses Go templates (`{{ .Values.something }}`), which mix templating logic with YAML in ways that are hard to read and debug. Kustomize keeps your manifests as valid YAML at all times — you can `kubectl apply` the base directly. For your own app, this clarity is worth it. Helm is still the right choice for third-party charts where the community maintains the templates.

#### Gateway API (Conceptual)
Gateway API is the next-generation routing API for Kubernetes, replacing the Ingress API.

- Read: [Gateway API Introduction](https://gateway-api.sigs.k8s.io/)
- Read: [Getting Started with Gateway API](https://gateway-api.sigs.k8s.io/guides/getting-started/)

Key concepts:
- **GatewayClass** — Defines the controller (Traefik, in our case). Like a "driver" for the gateway.
- **Gateway** — The actual listener. Binds to ports (80, 443) and defines TLS configuration.
- **HTTPRoute** — Routes traffic from the Gateway to your Services based on hostname, path, headers, etc.

The mental model: `GatewayClass` (who handles traffic) → `Gateway` (where to listen) → `HTTPRoute` (where to send it).

### Learn During

- How `kubectl kustomize <dir>` renders the final YAML — run it often to see what your changes produce.
- How JSON patches work (`op: replace`, `path: /spec/...`) — you'll write these in overlays.
- How ArgoCD Application manifests describe "what to deploy where" — they're just YAML resources themselves.

### Production-Readiness at This Phase
You're not on a cluster yet, so "production-ready" means: all manifests render valid YAML, the repo structure is clean, and you understand every line you wrote.

---

## Phase 2: OVH Cluster Setup

### Learn Before

#### How Managed Kubernetes Works
OVH (and AWS EKS, GCP GKE, Azure AKS) provides the **control plane** (API server, etcd, scheduler, controller manager). You only manage **worker nodes** — the VMs that run your containers.

- Read: [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/)
- Read: [OVH Managed Kubernetes Documentation](https://help.ovhcloud.com/csm/en-public-cloud-kubernetes-overview)

Key concepts:
- **Control plane** — The brain. Managed by OVH. You interact with it via `kubectl` and the API server.
- **Worker nodes** — The muscle. VMs where your Pods actually run. You choose the size and count.
- **Node pool** — A group of identically-sized nodes. Start with one pool. You can add more later (e.g., a pool with GPU nodes).
- **kubeconfig** — The file that tells `kubectl` how to connect to your cluster. Contains the API server URL and authentication credentials.

#### kubectl Basics
`kubectl` is your primary interface to the cluster. Learn these commands:

- Read: [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)

Essential commands:
```bash
kubectl get <resource>             # List resources
kubectl describe <resource> <name> # Detailed info
kubectl logs <pod> [-c container]  # View logs
kubectl exec -it <pod> -- bash     # Shell into a pod
kubectl apply -f <file>            # Create/update from YAML
kubectl delete -f <file>           # Delete from YAML
kubectl get events --sort-by='.lastTimestamp'  # Recent events
```

#### SOPS + age (Encryption)
SOPS encrypts individual values in YAML files while keeping the structure and keys readable. `age` is the encryption algorithm (simpler than PGP).

- Read: [SOPS README](https://github.com/getsops/sops)
- Read: [age README](https://github.com/FiloSottile/age)

Key concepts:
- **age keypair** — A public key (for encrypting) and private key (for decrypting). The public key goes in `.sops.yaml`. The private key stays on your machine and in the cluster.
- **`.sops.yaml`** — Config file that tells SOPS which key to use for which files (matched by path regex).
- **`sops -e -i file.yaml`** — Encrypt a file in-place. Values become `ENC[AES256_GCM,data:...,type:str]`.
- **`sops -d file.yaml`** — Decrypt and print to stdout.
- **`sops file.yaml`** — Open in your editor with values decrypted. Saves re-encrypted.

### Learn During

- How kubeconfig contexts work — you can have multiple clusters configured and switch between them with `kubectl config use-context`.
- The difference between namespaces (`staging` vs `production`) and how they provide isolation.
- How `age-keygen` works and why you need to back up the private key.

### Production-Readiness at This Phase
The cluster exists, you can reach it, and namespaces are created. Not much to go wrong here, but verify node health and that you can create resources.

---

## Phase 3: ArgoCD + Infrastructure Services

### Learn Before

#### ArgoCD Core Concepts
ArgoCD is a GitOps controller: it watches a Git repo and ensures the cluster matches what's in Git.

- Read: [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- Read: [ArgoCD Core Concepts](https://argo-cd.readthedocs.io/en/stable/core_concepts/)
- Read: [App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern)

Key concepts:
- **Application** — The fundamental ArgoCD resource. Maps a Git path to a cluster namespace. ArgoCD watches the Git path and syncs changes to the cluster.
- **Sync** — The process of making the cluster match Git. Can be manual or automatic.
- **Health** — ArgoCD checks if resources are actually working (not just created). A Deployment is "Healthy" when all replicas are ready.
- **Sync Status** — `Synced` means cluster matches Git. `OutOfSync` means there's a diff.
- **App of Apps** — A pattern where one Application manages other Applications. This is how we bootstrap everything from a single `kubectl apply`.
- **Self-Heal** — When enabled, ArgoCD reverts manual changes made to the cluster (e.g., someone `kubectl edit`s a Deployment).
- **Prune** — When enabled, ArgoCD deletes resources that were removed from Git.

**The ArgoCD UI** is your best learning tool. It shows:
- Resource trees (Deployment → ReplicaSet → Pods)
- Live diffs between Git and cluster state
- Event logs
- Sync history

#### Helm (for Third-Party Charts)
You're using Helm for installing community-maintained charts, not for your own app.

- Read: [Helm Concepts](https://helm.sh/docs/intro/using_helm/)
- Read: [Helm Chart Repositories](https://helm.sh/docs/helm/helm_repo/)

Key concepts:
- **Chart** — A package of K8s resources with configurable values.
- **Repository** — Where charts are hosted (e.g., `https://charts.bitnami.com/bitnami`).
- **Values** — Configuration overrides. You pass these via `helm install --values` or, in our case, via the ArgoCD Application's `spec.source.helm.values`.
- **Release** — An instance of a chart installed in the cluster.

You won't run `helm install` manually — ArgoCD does it for you based on the Application manifests.

#### CloudNativePG
CloudNativePG is a Kubernetes operator that manages PostgreSQL clusters.

- Read: [CloudNativePG Architecture](https://cloudnative-pg.io/documentation/current/architecture/)
- Read: [CloudNativePG Quickstart](https://cloudnative-pg.io/documentation/current/quickstart/)

Key concepts:
- **Operator pattern** — A controller that watches Custom Resources (CRs) and manages complex software. CloudNativePG watches `Cluster` CRs and manages PostgreSQL pods, PVCs, services, and secrets.
- **Cluster CR** — Your declaration of what you want: how many instances, storage size, PostgreSQL parameters, backup config.
- **Primary and Standby** — In HA mode (instances > 1), one pod is primary (read-write) and others are standbys (read-only, can be promoted).
- **`-rw` Service** — Points to the primary. This is what your `DATABASE_URL` should reference.
- **`-r` Service** — Points to standbys (for read-only queries).
- **PVC management** — CloudNativePG manages its own PVCs (does NOT use StatefulSets). This gives it more control over failover and data safety.

#### Traefik
Traefik is a modern reverse proxy / ingress controller with native Gateway API support.

- Read: [Traefik Kubernetes Gateway Provider](https://doc.traefik.io/traefik/providers/kubernetes-gateway/)
- Read: [Traefik Dashboard](https://doc.traefik.io/traefik/operations/dashboard/)

Key concepts:
- Traefik runs as a Deployment with a LoadBalancer Service (gets an external IP from OVH).
- It watches Gateway and HTTPRoute resources and configures routing automatically.
- The built-in dashboard shows active routes, services, and middlewares — useful for debugging.

#### cert-manager
cert-manager automates TLS certificate management.

- Read: [cert-manager Concepts](https://cert-manager.io/docs/concepts/)
- Read: [cert-manager with Gateway API](https://cert-manager.io/docs/usage/gateway/)

Key concepts:
- **Issuer / ClusterIssuer** — Defines where to get certificates from (Let's Encrypt, self-signed, etc.).
- **Certificate** — A request for a TLS certificate. cert-manager creates the certificate and stores it as a K8s Secret.
- **ACME** — The protocol Let's Encrypt uses. cert-manager handles the challenge/response automatically.
- **HTTP-01 challenge** — Proves you own a domain by serving a specific file. cert-manager creates a temporary HTTPRoute for this.

### Learn During

- How to read the ArgoCD UI — spend time clicking through the resource tree, viewing diffs, and understanding sync states.
- How ArgoCD handles Helm charts — it doesn't run `helm install`, it renders the chart and applies the YAML (like `helm template` + `kubectl apply`).
- How to debug pods that won't start: `kubectl describe pod`, `kubectl logs`, `kubectl get events`.
- How OVH provisions LoadBalancer IPs — the Traefik Service gets an external IP from OVH's cloud infrastructure.

### Production-Readiness at This Phase
All infrastructure services are running and managed by ArgoCD. If someone manually changes something on the cluster, ArgoCD reverts it (self-heal). This is a major improvement over manually-managed infrastructure.

**What "production-ready" means here:**
- All ArgoCD Applications show Synced + Healthy
- Traefik has an external IP
- CloudNativePG cluster is in healthy state
- cert-manager can issue certificates
- Redis is accepting connections

---

## Phase 4: App Deployment (Staging)

### Learn Before

#### Pods, Deployments, and ReplicaSets
The core workload resources in Kubernetes.

- Read: [Pods](https://kubernetes.io/docs/concepts/workloads/pods/)
- Read: [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)

Key concepts:
- **Pod** — The smallest deployable unit. One or more containers that share networking and storage. You almost never create Pods directly.
- **ReplicaSet** — Ensures a specified number of Pod replicas are running. Created by Deployments — you don't manage these directly either.
- **Deployment** — Declares the desired state for a set of Pods. Handles rolling updates, rollbacks, and scaling. This is what you write in your manifests.
- **Init Containers** — Containers that run before the main container. Used for migrations, waiting for dependencies, etc. If an init container fails, the Pod restarts.

#### Services and Networking
How pods communicate.

- Read: [Services](https://kubernetes.io/docs/concepts/services-networking/service/)
- Read: [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

Key concepts:
- **ClusterIP** — Internal-only IP. Other pods reach it via DNS: `<service-name>.<namespace>.svc.cluster.local` or just `<service-name>` within the same namespace.
- **Service discovery** — Your app reaches PostgreSQL via `notafilia-pg-rw.staging:5432`. K8s DNS resolves this to the service's ClusterIP.
- **Cross-namespace access** — Use the FQDN: `notafilia-pg-rw.staging.svc.cluster.local`.

#### ConfigMaps and Secrets
How to pass configuration to containers.

- Read: [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- Read: [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

Key concepts:
- **ConfigMap** — Non-sensitive key-value pairs. Injected as environment variables via `envFrom`.
- **Secret** — Sensitive data (base64-encoded in etcd). Same injection mechanism, but with access controls.
- **`envFrom`** — Injects all key-value pairs from a ConfigMap or Secret as environment variables. Simpler than listing each env var individually.

#### Environment Variables in Django
How the app consumes configuration.

- The app uses `os.environ.get("DATABASE_URL")` and `dj-database-url` to parse the connection string.
- `DJANGO_SETTINGS_MODULE` tells Django which settings file to use.
- The `settings_production.py` module imports `settings.py` and overrides specific values.

### Learn During

- How to debug failed init containers (migrations): `kubectl logs <pod> -c migrate -n staging`
- How SOPS encryption/decryption works in practice — edit encrypted files with `sops overlays/staging/secrets.enc.yaml`
- How ArgoCD shows the diff between Git and cluster state when secrets change.
- How to verify environment variables inside a running pod: `kubectl exec -it <pod> -n staging -- env | grep DATABASE`

### Production-Readiness at This Phase
The app is running in staging. You can access it via HTTPS. Migrations ran successfully. All 3 components (web, celery, beat) are healthy.

**What to verify:**
- Can you log in?
- Do Celery tasks execute?
- Are scheduled tasks (beat) firing on time?
- Is the TLS certificate valid?
- Do health check endpoints respond?

---

## Phase 5: CI/CD (GitHub Actions)

### Learn Before

#### GitHub Actions for Docker
- Read: [GitHub Actions: Publishing Docker images](https://docs.github.com/en/actions/use-cases-and-examples/publishing-packages/publishing-docker-images)
- Read: [docker/build-push-action](https://github.com/docker/build-push-action)

Key concepts:
- **GHCR (GitHub Container Registry)** — Docker registry at `ghcr.io`. Free for public repos, generous limits for private.
- **OIDC authentication** — `${{ secrets.GITHUB_TOKEN }}` is automatically available in every workflow. No need to store registry credentials as secrets.
- **Build caching** — `cache-from: type=gha` caches Docker layers in GitHub's cache storage. Subsequent builds only rebuild changed layers.

#### ArgoCD Image Updater (Optional)
- Read: [ArgoCD Image Updater Docs](https://argocd-image-updater.readthedocs.io/)

Key concepts:
- Watches container registries for new image tags.
- Updates the running application in ArgoCD when a new tag matching your pattern appears.
- Can write back to Git (so the repo stays the source of truth) or update in-memory only.

#### GitOps Image Update Strategies
There are two approaches to updating images:

1. **Push-based** (simpler): CI pushes a commit to the infra repo updating the image tag. ArgoCD syncs the change.
2. **Pull-based** (Image Updater): ArgoCD watches the registry and updates automatically.

For learning, push-based is easier to understand. For production, pull-based is more GitOps-pure.

### Learn During

- How GitHub Actions OIDC works for registry authentication.
- How Docker layer caching dramatically speeds up builds.
- The full loop: code push → image build → tag update → ArgoCD sync → new pods.
- How to roll back: just revert the image tag in Git and ArgoCD syncs the old version.

### Production-Readiness at This Phase
You have automated delivery. Code changes flow through to staging automatically. Production is still manually promoted (deliberate choice for safety).

**What to verify:**
- Push to main → GitHub Actions builds and pushes an image
- The image appears in GHCR
- ArgoCD detects the change and syncs staging
- The new code is live in staging

---

## Phase 6: Production

### Learn Before

#### Production Concerns
- Read: [K8s Production Best Practices](https://kubernetes.io/docs/setup/production-environment/)
- Read: [Pod Disruption Budgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)

Key concepts:
- **Pod Disruption Budget (PDB)** — Guarantees minimum availability during voluntary disruptions (node upgrades, scaling). `minAvailable: 1` ensures at least 1 web pod is always running.
- **Resource requests vs limits** — Requests are guaranteed (the scheduler uses them for placement). Limits are max allowed. Set requests based on actual usage, limits with headroom.
- **Rolling updates** — Deployments update pods gradually. One new pod comes up, one old pod goes down. Zero downtime if health checks are configured.

#### DNS and TLS
- Read: [cert-manager: Securing Gateway Resources](https://cert-manager.io/docs/usage/gateway/)

Key concepts:
- **A record** — Maps a domain to an IP. Point `notafilia.com` to the Traefik LoadBalancer IP.
- **Let's Encrypt rate limits** — 50 certificates per registered domain per week. Use the staging issuer (`acme-staging-v02.api.letsencrypt.org`) for testing.
- **HSTS** — HTTP Strict Transport Security. Once you're confident TLS works, enable it in `settings_production.py`.

#### Monitoring and Observability
Not in scope for initial deployment, but worth knowing about:

- Read: [Kubernetes Monitoring with Prometheus](https://prometheus.io/docs/introduction/overview/)
- Read: [Sentry for Django](https://docs.sentry.io/platforms/python/integrations/django/) (already in the app)

The app already has Sentry configured via `SENTRY_DSN`. For K8s-level monitoring, you can add Prometheus + Grafana later (another ArgoCD Application).

### Learn During

- How DNS propagation works and why it can take hours.
- How cert-manager's ACME HTTP-01 challenge works in practice (creates temporary routes).
- How to monitor production pods: `kubectl top pods`, `kubectl logs --follow`.
- The difference between staging and production ArgoCD sync policies (prune: false in production).

### Production-Readiness at This Phase
This IS production-ready. Specifically:

| Aspect | Status |
|--------|--------|
| TLS | cert-manager auto-renews Let's Encrypt certificates |
| High availability | 2 web replicas with PodDisruptionBudget |
| Database | CloudNativePG with standby (automated failover) |
| Secrets | Encrypted at rest (SOPS), decrypted only at sync time |
| GitOps | All changes through Git, ArgoCD auto-syncs |
| CI/CD | Automated builds, manual production promotion |
| Rollback | Revert the image tag in Git |
| Monitoring | Sentry for app errors, ArgoCD for infrastructure health |

**What's NOT included (and can be added later):**
- Database backups to S3 (CloudNativePG supports this natively)
- Prometheus + Grafana for metrics
- Horizontal Pod Autoscaler (HPA)
- Network policies for namespace isolation
- ArgoCD notifications (Slack/email on sync failures)

---

## Recommended Reading Order

### Before Starting Anything
1. [Understanding Kubernetes Objects](https://kubernetes.io/docs/concepts/overview/working-with-objects/) (15 min)
2. [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/) (10 min)
3. [Kustomize Tutorial](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) (20 min)

### Before Phase 2
4. [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/) (bookmark this)
5. [SOPS README](https://github.com/getsops/sops) (15 min, focus on age encryption)

### Before Phase 3
6. [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/) (30 min, follow along)
7. [App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern) (10 min)
8. [Gateway API Introduction](https://gateway-api.sigs.k8s.io/) (15 min)
9. [CloudNativePG Quickstart](https://cloudnative-pg.io/documentation/current/quickstart/) (20 min)

### Before Phase 4
10. [Pods](https://kubernetes.io/docs/concepts/workloads/pods/) (10 min)
11. [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) (15 min)
12. [Services](https://kubernetes.io/docs/concepts/services-networking/service/) (10 min)
13. [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) (10 min)

### Before Phase 5
14. [GitHub Actions: Publishing Docker images](https://docs.github.com/en/actions/use-cases-and-examples/publishing-packages/publishing-docker-images) (15 min)

### Before Phase 6
15. [Pod Disruption Budgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/) (10 min)
16. [cert-manager: Securing Gateway Resources](https://cert-manager.io/docs/usage/gateway/) (15 min)

**Total estimated reading: ~4-5 hours**, spread across the phases. Most of the learning happens by doing.

---

## Quick Reference: Debugging Commands

These are the commands you'll use most often when things go wrong:

```bash
# What's running?
kubectl get pods -n staging
kubectl get pods -n production

# Why won't my pod start?
kubectl describe pod <pod-name> -n staging
kubectl get events -n staging --sort-by='.lastTimestamp'

# What are the logs?
kubectl logs <pod-name> -n staging                    # Main container
kubectl logs <pod-name> -n staging -c migrate         # Init container
kubectl logs <pod-name> -n staging --previous         # Previous crash

# What's inside the pod?
kubectl exec -it <pod-name> -n staging -- bash
kubectl exec -it <pod-name> -n staging -- env | grep DATABASE

# Is my service reachable?
kubectl run debug --image=busybox --rm -it --restart=Never -- wget -qO- http://notafilia-web.staging:8000/health/

# What does ArgoCD think?
argocd app list
argocd app get notafilia-staging
argocd app diff notafilia-staging

# What resources exist?
kubectl get all -n staging
kubectl get clusters.postgresql.cnpg.io -n staging
kubectl get httproutes -n staging
kubectl get certificates -n staging

# Resource usage
kubectl top pods -n staging
kubectl top nodes
```

---

## Glossary

| Term | Meaning |
|------|---------|
| **CRD** | Custom Resource Definition — extends the K8s API with new resource types (e.g., `Cluster` for CloudNativePG) |
| **CR** | Custom Resource — an instance of a CRD |
| **Operator** | A controller that watches CRs and manages complex software (CloudNativePG, cert-manager) |
| **GitOps** | Infrastructure managed through Git. The repo is the single source of truth. |
| **Reconciliation** | The process of making actual state match desired state. ArgoCD reconciles Git → cluster. |
| **Self-heal** | ArgoCD reverts manual changes to match Git |
| **Prune** | ArgoCD deletes resources removed from Git |
| **SOPS** | Secrets OPerationS — encrypts values in YAML files |
| **age** | Modern encryption tool. Simpler alternative to PGP. |
| **PVC** | Persistent Volume Claim — how pods request durable storage |
| **Init container** | A container that runs before the main container (used for migrations) |
| **LoadBalancer** | Service type that gets an external IP from the cloud provider |
| **ClusterIP** | Service type that's only reachable within the cluster |
| **HTTPRoute** | Gateway API resource that routes HTTP traffic to Services |
| **HelmRelease / Application** | How GitOps tools (Flux / ArgoCD) install Helm charts declaratively |
