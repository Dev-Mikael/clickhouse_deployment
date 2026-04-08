# ClickHouse GitOps Deployment — Implementation Guide

> **Stack:** FluxCD v2 · Altinity ClickHouse Operator · ZooKeeper · Sealed Secrets · cert-manager · Azure Disk (managed-premium)
>
> **Topology:** 2 shards × 2 replicas = **4 ClickHouse pods** — production-grade, replicated, HA

---

## Table of Contents

1. [What You're Building](#1-what-youre-building)
2. [How Everything Fits Together](#2-how-everything-fits-together)
3. [Prerequisites](#3-prerequisites)
4. [Repository Structure Explained](#4-repository-structure-explained)
5. [Step-by-Step Deployment](#5-step-by-step-deployment)
6. [Generating the Sealed Secret](#6-generating-the-sealed-secret)
7. [Verifying the Deployment](#7-verifying-the-deployment)
8. [Connecting to ClickHouse](#8-connecting-to-clickhouse)
9. [Understanding the Cluster Topology](#9-understanding-the-cluster-topology)
10. [Troubleshooting](#10-troubleshooting)
11. [Key Concepts Glossary](#11-key-concepts-glossary)

---

## 1. What You're Building

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your AKS Cluster                         │
│                                                                 │
│  ┌─────────────┐   ┌──────────────────────────────────────┐    │
│  │  flux-system │   │          clickhouse-operator          │    │
│  │  (FluxCD)   │──▶│  Watches for ClickHouseInstallation  │    │
│  └─────────────┘   │  CRs and creates pods automatically  │    │
│         │          └──────────────────────────────────────┘    │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────┐   ┌──────────────────────────────────────┐    │
│  │  zookeeper  │   │            clickhouse                 │    │
│  │  (3 pods)   │◀──│  chi-clickhouse-production-cluster-  │    │
│  │  Port 2181  │   │  0-0  (shard-0, replica-0)           │    │
│  └─────────────┘   │  0-1  (shard-0, replica-1)           │    │
│                    │  1-0  (shard-1, replica-0)           │    │
│  ┌─────────────┐   │  1-1  (shard-1, replica-1)           │    │
│  │sealed-secrets│  └──────────────────────────────────────┘    │
│  │cert-manager │                                               │
│  └─────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

**ClickHouse** is a high-performance columnar database used for analytics. It's not a drop-in for PostgreSQL — it's purpose-built for OLAP workloads (aggregations, reporting, time-series).

---

## 2. How Everything Fits Together

### The GitOps Flow

```
Your Laptop  ──git push──▶  GitHub Repo
                                │
                           FluxCD polls
                           every 10 min
                                │
                                ▼
                         Applies manifests
                         to the cluster in
                         dependency order:
                         sources → controllers → apps
```

### Dependency Chain (why this order matters)

```
sources          — registers Helm chart repositories (no deps)
    │
    ▼
controllers      — installs 4 operators using those chart sources
  ├── cert-manager        (issues internal TLS certs)
  ├── sealed-secrets      (decrypts SealedSecrets → real Secrets)
  ├── clickhouse-operator (understands ClickHouseInstallation CRD)
  └── zookeeper           (coordinates ClickHouse replication)
    │
    ▼
apps/clickhouse  — deploys the actual database (depends on all controllers)
  ├── namespace.yaml
  ├── cluster-issuer.yaml   (cert-manager CA setup)
  ├── certificate.yaml      (TLS cert for ClickHouse)
  ├── tls-config.yaml       (ConfigMap: XML config for ClickHouse TLS)
  ├── sealed-secret.yaml    (encrypted admin password)
  └── clickhouse-installation.yaml  (the 4-pod cluster)
```

---

## 3. Prerequisites

Install these tools on your local machine before starting.

### Required tools

| Tool | Install command | What it does |
|------|----------------|--------------|
| `kubectl` | [docs.kubernetes.io](https://kubernetes.io/docs/tasks/tools/) | Talk to the cluster |
| `flux` CLI | `curl -s https://fluxcd.io/install.sh \| sudo bash` | Bootstrap FluxCD |
| `kubeseal` | `brew install kubeseal` or GitHub releases | Encrypt secrets |
| `git` | pre-installed on most systems | Version control |

### Required cluster state

```bash
# Verify your cluster is reachable
kubectl cluster-info

# Verify you have cluster-admin (needed for FluxCD bootstrap)
kubectl auth can-i '*' '*' --all-namespaces

# Verify the Azure storage class is available
kubectl get storageclass managed-premium
```

### GitHub Personal Access Token (PAT)

FluxCD needs to read/write to your repo during bootstrap.

1. Go to GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
2. Grant **Contents: Read and Write** on your `clickhouse-gitops` repository
3. Save the token — you'll use it in Step 5

---

## 4. Repository Structure Explained

```
clickhouse-gitops/
├── .github/workflows/
│   └── validate.yaml          # CI: validates all manifests on every PR
│
├── clusters/production/
│   ├── flux-system/           # AUTO-MANAGED by FluxCD — do not edit
│   ├── sources.yaml           # FluxCD Kustomization → infrastructure/sources
│   ├── controllers.yaml       # FluxCD Kustomization → infrastructure/controllers
│   └── apps.yaml              # FluxCD Kustomization → apps/clickhouse
│
├── infrastructure/
│   ├── sources/               # HelmRepository objects (chart URLs)
│   │   ├── altinity-helmrepo.yaml
│   │   ├── bitnami-helmrepo.yaml
│   │   ├── jetstack-helmrepo.yaml
│   │   └── sealed-secrets-helmrepo.yaml
│   │
│   └── controllers/           # HelmRelease objects (the actual operators)
│       ├── cert-manager/
│       ├── sealed-secrets/
│       ├── clickhouse-operator/
│       └── zookeeper/
│
└── apps/clickhouse/           # The ClickHouse database itself
    ├── namespace.yaml
    ├── cluster-issuer.yaml    # cert-manager CA chain
    ├── certificate.yaml       # TLS cert for ClickHouse pods
    ├── tls-config.yaml        # XML config telling ClickHouse to use the cert
    ├── sealed-secret.yaml     # Encrypted admin password (YOU must generate this)
    └── clickhouse-installation.yaml  # The main ClickHouseInstallation CR
```

---

## 5. Step-by-Step Deployment

### Step 1 — Create the GitHub repository

```bash
# Create the repo on GitHub first (via UI or gh CLI), then:
git clone https://github.com/YOUR_USERNAME/clickhouse-gitops
cd clickhouse-gitops

# Copy all files from this zip into the repo root
# Then verify the structure:
find . -name "*.yaml" | sort
```

### Step 2 — Generate the Sealed Secret (CRITICAL — do this before pushing)

> ⚠️ **Do NOT skip this step.** Pushing with the placeholder value will break the deployment.

See **Section 6** for the full Sealed Secret generation process.

### Step 3 — Bootstrap FluxCD

```bash
export GITHUB_TOKEN=ghp_YOUR_TOKEN_HERE
export GITHUB_USER=YOUR_GITHUB_USERNAME

flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=clickhouse-gitops \
  --branch=main \
  --path=clusters/production \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
```

**What happens during bootstrap:**
- FluxCD installs itself into the `flux-system` namespace
- It creates a `GitRepository` pointing to your GitHub repo
- It creates a `Kustomization` for `clusters/production/`
- FluxCD then reads `sources.yaml`, `controllers.yaml`, and `apps.yaml` and starts reconciling

### Step 4 — Watch the rollout

Open a second terminal and watch resources come up in order:

```bash
# Watch FluxCD Kustomizations reconcile
watch flux get kustomizations

# Expected output after ~10-15 minutes:
# NAME          READY   STATUS
# flux-system   True    Applied revision: main/abc1234
# sources       True    Applied revision: main/abc1234
# controllers   True    Applied revision: main/abc1234
# apps          True    Applied revision: main/abc1234

# Watch HelmReleases install
watch flux get helmreleases --all-namespaces

# Watch ClickHouse pods come up (4 pods)
watch kubectl get pods -n clickhouse
```

### Step 5 — Verify

See **Section 7** for full verification steps.

---

## 6. Generating the Sealed Secret

This is a two-part process: first install the sealed-secrets controller (done via FluxCD), then use `kubeseal` to encrypt your password.

### Wait for the controller to be ready

```bash
# After bootstrap, wait for sealed-secrets to be running
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=sealed-secrets \
  -n sealed-secrets \
  --timeout=120s
```

### Generate and seal the secret

```bash
# Choose a strong password
export CLICKHOUSE_ADMIN_PASSWORD="YourStrongPasswordHere123!"

# Create the secret locally and pipe it directly to kubeseal
kubectl create secret generic clickhouse-credentials \
  --from-literal=admin-password=${CLICKHOUSE_ADMIN_PASSWORD} \
  --namespace=clickhouse \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace=sealed-secrets \
    --controller-name=sealed-secrets-controller \
    --format=yaml \
> apps/clickhouse/sealed-secret.yaml

# Verify the output — it should have a long base64-encoded encryptedData block
cat apps/clickhouse/sealed-secret.yaml
```

### Commit and push

```bash
git add apps/clickhouse/sealed-secret.yaml
git commit -m "feat: add sealed clickhouse credentials"
git push

# Force FluxCD to reconcile immediately (don't wait 10 min)
flux reconcile kustomization apps --with-source
```

> 💡 The SealedSecret is safe to commit — it's encrypted with the cluster's public key and can only be decrypted by the sealed-secrets controller running on that specific cluster.

---

## 7. Verifying the Deployment

Run these checks in order. Each should pass before moving to the next.

### Check 1 — All FluxCD Kustomizations are Ready

```bash
flux get kustomizations
# All four (flux-system, sources, controllers, apps) should show READY=True
```

### Check 2 — All HelmReleases installed successfully

```bash
flux get helmreleases --all-namespaces
# Expected: cert-manager, sealed-secrets, clickhouse-operator, zookeeper — all READY=True
```

### Check 3 — ZooKeeper quorum is healthy

```bash
kubectl get pods -n zookeeper
# Expected: zookeeper-0, zookeeper-1, zookeeper-2 — all Running

# Test ZooKeeper is accepting connections
kubectl exec -n zookeeper zookeeper-0 -- zkServer.sh status
# Expected: "Mode: leader" or "Mode: follower"
```

### Check 4 — ClickHouse Operator is running

```bash
kubectl get pods -n clickhouse-operator
# Expected: clickhouse-operator-... — Running
```

### Check 5 — ClickHouse pods are all running

```bash
kubectl get pods -n clickhouse
# Expected 4 pods named like:
# chi-clickhouse-production-cluster-0-0-0   Running
# chi-clickhouse-production-cluster-0-1-0   Running
# chi-clickhouse-production-cluster-1-0-0   Running
# chi-clickhouse-production-cluster-1-1-0   Running
```

### Check 6 — ClickHouseInstallation is Completed

```bash
kubectl get clickhouseinstallation -n clickhouse
# STATUS should be: Completed

# Get full details
kubectl describe clickhouseinstallation clickhouse -n clickhouse
```

### Check 7 — TLS Certificate was issued

```bash
kubectl get certificate -n clickhouse
# READY should be: True

kubectl get secret clickhouse-tls-secret -n clickhouse
# Should exist with keys: tls.crt, tls.key, ca.crt
```

---

## 8. Connecting to ClickHouse

ClickHouse is ClusterIP-only, so you connect via `kubectl exec` or port-forward from inside the cluster.

### Option A — Port-forward and connect locally

```bash
# Forward the native TCP port from one of the pods
kubectl port-forward \
  pod/chi-clickhouse-production-cluster-0-0-0 \
  9000:9000 \
  -n clickhouse

# In a separate terminal, connect with clickhouse-client
# Install: brew install clickhouse / apt install clickhouse-client
clickhouse-client \
  --host 127.0.0.1 \
  --port 9000 \
  --user admin \
  --password YOUR_ADMIN_PASSWORD \
  --secure
```

### Option B — Exec directly into a pod (fastest for quick checks)

```bash
kubectl exec -it \
  pod/chi-clickhouse-production-cluster-0-0-0 \
  -n clickhouse \
  -- clickhouse-client --user admin --password YOUR_ADMIN_PASSWORD
```

### Option C — Use the HTTPS interface

```bash
kubectl port-forward \
  pod/chi-clickhouse-production-cluster-0-0-0 \
  8443:8443 \
  -n clickhouse

# Query via curl
curl -k \
  --user admin:YOUR_ADMIN_PASSWORD \
  'https://localhost:8443/?query=SELECT+version()'
```

### Useful first queries

```sql
-- Check ClickHouse version
SELECT version();

-- Verify all 4 nodes are in the cluster
SELECT * FROM system.clusters WHERE cluster = 'production-cluster';

-- Check replication is working
SELECT * FROM system.replicas;

-- Check ZooKeeper connectivity
SELECT * FROM system.zookeeper WHERE path = '/';
```

---

## 9. Understanding the Cluster Topology

### Shards vs Replicas — the key distinction

```
production-cluster
├── Shard 0  (holds data partition A)
│   ├── Replica 0  ← pod: chi-...-0-0-0  (primary for shard 0)
│   └── Replica 1  ← pod: chi-...-0-1-0  (hot standby for shard 0)
│
└── Shard 1  (holds data partition B)
    ├── Replica 0  ← pod: chi-...-1-0-0  (primary for shard 1)
    └── Replica 1  ← pod: chi-...-1-1-0  (hot standby for shard 1)
```

**Shard** = horizontal data partition. Data is split across shards for scale-out write/query performance.

**Replica** = full copy of a shard. If replica-0 of shard-0 dies, replica-1 takes over automatically. ZooKeeper coordinates this failover.

**What ZooKeeper does:** it stores the replication metadata — which parts of data each replica has, what's pending sync, and who the current leader is. Without ZooKeeper, replicas cannot coordinate and replication stops.

### Azure PVC allocation

Each of the 4 ClickHouse pods gets its own PVC:
- **Data volume:** 100Gi `managed-premium` per pod → 400Gi total
- **Log volume:** 10Gi `managed-premium` per pod → 40Gi total

```bash
# View all PVCs
kubectl get pvc -n clickhouse
```

---

## 10. Troubleshooting

### FluxCD Kustomization stuck / not Ready

```bash
# Get detailed status and events
flux describe kustomization apps

# Force re-reconcile
flux reconcile kustomization apps --with-source

# Check FluxCD controller logs
kubectl logs -n flux-system deploy/kustomize-controller -f
```

### HelmRelease failing

```bash
# See what went wrong
flux describe helmrelease clickhouse-operator -n clickhouse-operator

# Check Helm release history
helm history clickhouse-operator -n clickhouse-operator
```

### ClickHouse pods in Pending state

```bash
# Usually a PVC provisioning issue
kubectl describe pod chi-clickhouse-production-cluster-0-0-0 -n clickhouse

# Check PVC status
kubectl get pvc -n clickhouse
kubectl describe pvc -n clickhouse

# Verify the storage class exists on your AKS cluster
kubectl get storageclass managed-premium
```

### ClickHouse pods in CrashLoopBackOff

```bash
# Check ClickHouse logs
kubectl logs chi-clickhouse-production-cluster-0-0-0 -n clickhouse

# Common causes:
# 1. ZooKeeper not ready yet — wait and it will self-heal
# 2. Bad TLS config — check tls-config.yaml is correctly mounted
# 3. Sealed Secret not generated — the admin password Secret is missing
```

### Sealed Secret not decrypting

```bash
# Check the controller can see the SealedSecret
kubectl get sealedsecret -n clickhouse

# Check controller logs for errors
kubectl logs -n sealed-secrets \
  deploy/sealed-secrets-controller --tail=50

# The most common mistake: generating the SealedSecret before the controller
# was running. Re-generate it after the controller is healthy.
```

### ZooKeeper not forming quorum

```bash
kubectl get pods -n zookeeper

# If pods are pending, check node count
kubectl get nodes
# You need at least 3 nodes for the podAntiAffinity rule to be satisfied
# If you have fewer than 3 nodes, change requiredDuring... to preferredDuring...
# in infrastructure/controllers/zookeeper/helmrelease.yaml
```

### Check all events across namespaces

```bash
# Broad view of what's happening
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -30
```

---

## 11. Key Concepts Glossary

| Term | What it means |
|------|--------------|
| **FluxCD** | A GitOps operator — it continuously syncs your cluster to match your Git repo |
| **Kustomization (FluxCD)** | A FluxCD CR that points to a directory and applies its manifests |
| **HelmRepository** | Tells FluxCD where to download Helm charts from |
| **HelmRelease** | Tells FluxCD to install a Helm chart with specific values |
| **ClickHouseInstallation** | The CRD that Altinity operator reads to create the cluster |
| **SealedSecret** | An encrypted Secret safe to commit to Git; only the in-cluster controller can decrypt it |
| **ClusterIssuer** | A cert-manager resource that issues TLS certificates |
| **ZooKeeper** | A distributed coordination service — ClickHouse uses it to track replication state |
| **Shard** | A horizontal data partition across nodes |
| **Replica** | A full copy of a shard's data for high availability |
| **PodAntiAffinity** | A rule that forces pods to land on different physical nodes |
| **managed-premium** | Azure Disk Premium SSD storage class (fast, persistent block storage) |

---

## Common Commands Reference

```bash
# Watch everything at once
flux get all --all-namespaces

# Force sync from Git immediately
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source

# Suspend auto-sync (for maintenance)
flux suspend kustomization apps

# Resume auto-sync
flux resume kustomization apps

# See what FluxCD would change without applying
flux build kustomization apps --path ./apps/clickhouse --dry-run

# Watch pods across the whole cluster
kubectl get pods --all-namespaces -w

# Scale ClickHouse down (edit the CHI spec)
kubectl edit clickhouseinstallation clickhouse -n clickhouse
```
