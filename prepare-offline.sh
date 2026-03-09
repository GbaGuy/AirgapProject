#!/usr/bin/env bash
# ============================================================
# prepare-offline.sh
# Run this script WHILE ONLINE to download all Helm charts
# and container images needed for air-gapped deployment.
# Output: offline/ directory with charts/ and images/
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$SCRIPT_DIR/offline"
CHARTS_DIR="$OFFLINE_DIR/charts"
IMAGES_DIR="$OFFLINE_DIR/images"

source "$OFFLINE_DIR/manifest.sh"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
error() { echo "[ERROR] $*" >&2; }

# ---- Pre-flight ----
for cmd in helm docker; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd is required to prepare offline bundle"
    exit 1
  fi
done

mkdir -p "$CHARTS_DIR" "$IMAGES_DIR"

echo "============================================"
echo "  Preparing Offline Bundle"
echo "============================================"
echo ""

# ============================================================
# 1. Pull Helm Charts
# ============================================================
info "--- Downloading Helm Charts ---"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
helm repo update

info "Pulling ingress-nginx chart v${CHART_INGRESS_NGINX_VERSION}..."
helm pull ingress-nginx/ingress-nginx --version "$CHART_INGRESS_NGINX_VERSION" -d "$CHARTS_DIR" --untar=false
ok "ingress-nginx chart saved"

info "Pulling argo-cd chart v${CHART_ARGOCD_VERSION}..."
helm pull argo/argo-cd --version "$CHART_ARGOCD_VERSION" -d "$CHARTS_DIR" --untar=false
ok "argo-cd chart saved"

info "Pulling harbor chart v${CHART_HARBOR_VERSION}..."
helm pull harbor/harbor --version "$CHART_HARBOR_VERSION" -d "$CHARTS_DIR" --untar=false
ok "harbor chart saved"

# Copy local networktools chart
info "Packaging networktools chart..."
helm package "$SCRIPT_DIR/networktools" -d "$CHARTS_DIR" >/dev/null
ok "networktools chart packaged"

echo ""

# ============================================================
# 2. Pull and Save Container Images
# ============================================================
info "--- Downloading Container Images ---"
info "This may take a while depending on your connection..."
echo ""

FAILED_IMAGES=()
for image in "${IMAGES[@]}"; do
  info "Pulling: $image"
  if docker pull "$image" 2>/dev/null; then
    ok "  Pulled $image"
  else
    error "  Failed to pull $image"
    FAILED_IMAGES+=("$image")
  fi
done

if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
  echo ""
  error "Failed to pull ${#FAILED_IMAGES[@]} image(s):"
  for img in "${FAILED_IMAGES[@]}"; do
    error "  - $img"
  done
  echo ""
  error "Fix the above and re-run. Continuing with available images..."
fi

# Save all images into a single tar
info "Saving all images to offline/images/all-images.tar ..."
AVAILABLE_IMAGES=()
for image in "${IMAGES[@]}"; do
  if docker image inspect "$image" &>/dev/null; then
    AVAILABLE_IMAGES+=("$image")
  fi
done

if [ ${#AVAILABLE_IMAGES[@]} -gt 0 ]; then
  docker save "${AVAILABLE_IMAGES[@]}" -o "$IMAGES_DIR/all-images.tar"
  ok "Saved ${#AVAILABLE_IMAGES[@]} images to all-images.tar"

  # Compress
  info "Compressing images (gzip)..."
  gzip -f "$IMAGES_DIR/all-images.tar"
  ok "Compressed to all-images.tar.gz"
else
  error "No images available to save!"
  exit 1
fi

echo ""

# ============================================================
# Summary
# ============================================================
echo "============================================"
echo "  Offline Bundle Ready!"
echo "============================================"
echo ""
echo "  Charts:"
ls -lh "$CHARTS_DIR"/*.tgz 2>/dev/null | awk '{print "    " $NF " (" $5 ")"}'
echo ""
echo "  Images:"
ls -lh "$IMAGES_DIR"/*.tar.gz 2>/dev/null | awk '{print "    " $NF " (" $5 ")"}'
echo ""
TOTAL_SIZE=$(du -sh "$OFFLINE_DIR" | awk '{print $1}')
echo "  Total bundle size: $TOTAL_SIZE"
echo ""
echo "  Transfer the entire AirgapProject/ folder to"
echo "  the air-gapped environment, then run:"
echo "    ./load-offline.sh   # load images into cluster"
echo "    ./start.sh          # deploy everything"
echo "============================================"
