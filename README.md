# Airgap Kubernetes Lab

A complete airgap deployment lab running **Harbor** registry + **ArgoCD** GitOps on a **Kind** (Kubernetes in Docker) cluster. All container images are mirrored to a local Harbor registry, simulating a fully offline / air-gapped environment.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Kind Cluster                          │
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Harbor     │  │   ArgoCD    │  │  networktools   │  │
│  │  (registry)  │  │  (GitOps)   │  │   (app pod)     │  │
│  └──────┬───────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                 │                   │           │
│  ┌──────┴─────────────────┴───────────────────┴────────┐ │
│  │              Nginx Ingress Controller                │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
         │                  │
    harbor.local       argocd.local
     (port 8080)        (port 8080)
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Kind | K8s 1.27.3 | Local Kubernetes cluster |
| Harbor | latest (Helm) | Private OCI/container registry |
| ArgoCD | v3.3.2 (chart 9.4.9) | GitOps continuous delivery |
| Nginx Ingress | latest (Helm) | Ingress controller (NodePort) |
| network-multitool | latest | Sample workload deployed via GitOps |

## Quick Start

### Prerequisites

- Docker
- [Kind](https://kind.sigs.k8s.io/)
- [Helm 3](https://helm.sh/)
- kubectl

### One-Command Install

```bash
kind create cluster
./scripts/full-install.sh
```

This runs all six steps end-to-end and produces a fully working airgap lab.

### Run Individual Steps

```bash
./scripts/full-install.sh step1   # Install Nginx Ingress + Harbor
./scripts/full-install.sh step2   # Configure Harbor (projects, Docker config)
./scripts/full-install.sh step3   # Mirror ArgoCD images to Harbor
./scripts/full-install.sh step4   # Create Git repo + networktools Helm chart
./scripts/full-install.sh step5   # Deploy ArgoCD offline (all images from Harbor)
./scripts/full-install.sh step6   # Create ArgoCD Application (GitOps auto-sync)
```

Numeric shorthand also works: `./scripts/full-install.sh 1 2 3`

## Project Structure

```
AirgapProject/
├── README.md
├── scripts/
│   ├── full-install.sh                 # Combined installer (all 6 steps)
│   ├── 01-install-ingress-harbor.sh    # Step 1: Ingress + Harbor
│   ├── 02-configure-harbor.sh          # Step 2: Harbor configuration
│   ├── 03-prepare-argocd-images.sh     # Step 3: Mirror ArgoCD images
│   ├── 04-create-git-repo-helmchart.sh # Step 4: Git repo + Helm chart
│   ├── 05-deploy-argocd-offline.sh     # Step 5: Offline ArgoCD deploy
│   ├── 06-create-argocd-application.sh # Step 6: ArgoCD Application CR
│   ├── argo-cd-9.4.9.tgz              # Saved ArgoCD Helm chart (offline)
│   ├── argocd-application.yaml         # ArgoCD Application manifest
│   └── argocd-images.txt               # Image mapping reference
└── repos/
    └── helm-charts.git/                # Bare Git repo (GitOps source)
```

## How It Works

### Step 1 — Install Ingress + Harbor
Deploys Nginx Ingress Controller (NodePort 30080/30443) and Harbor registry via Helm. Harbor is exposed at `harbor.local:8080` through a port-forward.

### Step 2 — Configure Harbor
Creates `library` and `argocd` projects in Harbor, configures Docker's `daemon.json` for the insecure (HTTP) registry, and verifies Docker login.

### Step 3 — Mirror ArgoCD Images
Uses `helm template` to discover all images required by the ArgoCD chart, then pulls, re-tags, and pushes them to Harbor:
- `quay.io/argoproj/argocd:v3.3.2` → `harbor.local:8080/argocd/argocd:v3.3.2`
- `ghcr.io/dexidp/dex:v2.45.1` → `harbor.local:8080/argocd/dex:v2.45.1`
- `ecr-public.aws.com/.../redis:8.2.3-alpine` → `harbor.local:8080/argocd/redis:8.2.3-alpine`

Also downloads the chart `.tgz` for offline installation.

### Step 4 — Create Git Repo + Helm Chart
Mirrors `wbitt/network-multitool` to Harbor, creates a bare Git repository, and pushes a Helm chart (`networktools/`) with Deployment, Service, and ConfigMap templates.

### Step 5 — Deploy ArgoCD Offline
Configures the Kind node for Harbor access (DNS resolution via `/etc/hosts`, containerd HTTP registry config), then installs ArgoCD from the local `.tgz` chart with all image references pointing to Harbor.

### Step 6 — Create ArgoCD Application
Starts a `git daemon` to serve the bare repo over `git://` protocol, then creates an ArgoCD Application CR with automated sync, self-heal, and prune enabled. The `networktools` pod is deployed and managed via GitOps.

## Testing GitOps

After installation, push a change to the bare repo and watch ArgoCD auto-sync:

```bash
git clone repos/helm-charts.git /tmp/helm-edit
cd /tmp/helm-edit
# Edit networktools/values.yaml (e.g., change replicaCount to 2)
git commit -am "Scale to 2 replicas"
git push
# ArgoCD detects the change and reconciles automatically
```

## Access

| Service | URL | Credentials |
|---------|-----|-------------|
| Harbor | http://harbor.local:8080 | admin / Harbor12345 |
| ArgoCD | http://argocd.local:8080 | admin / *(run `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d`)* |

## Cleanup

```bash
kind delete cluster
```
