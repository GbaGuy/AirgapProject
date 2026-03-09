# ============================================================
# AirgapProject - Image & Chart Manifest
# ============================================================
# This file defines all container images and Helm chart versions
# required for offline/air-gapped deployment.
# Edit versions here — all scripts read from this file.
# ============================================================

# --- Helm Chart Versions ---
CHART_INGRESS_NGINX_VERSION="4.12.2"
CHART_ARGOCD_VERSION="9.4.9"
CHART_HARBOR_VERSION="1.16.0"

# --- Container Images ---
# ingress-nginx
IMAGES=(
  "registry.k8s.io/ingress-nginx/controller:v1.12.0"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.0"

  # argocd
  "quay.io/argoproj/argocd:v3.3.2"
  "ghcr.io/dexidp/dex:v2.43.0"
  "public.ecr.aws/docker/library/redis:8.2.3-alpine"

  # harbor
  "goharbor/harbor-core:v2.12.0"
  "goharbor/harbor-db:v2.12.0"
  "goharbor/harbor-jobservice:v2.12.0"
  "goharbor/harbor-portal:v2.12.0"
  "goharbor/harbor-registryctl:v2.12.0"
  "goharbor/redis-photon:v2.12.0"
  "goharbor/registry-photon:v2.12.0"
  "goharbor/trivy-adapter-photon:v2.12.0"

  # networktools
  "nicolaka/netshoot:latest"
)
