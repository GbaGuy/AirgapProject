#!/usr/bin/env bash
# ============================================================
# load-offline.sh
# Run this script IN THE AIR-GAPPED ENVIRONMENT to load
# all container images and make Helm charts available.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$SCRIPT_DIR/offline"
CHARTS_DIR="$OFFLINE_DIR/charts"
IMAGES_DIR="$OFFLINE_DIR/images"

source "$OFFLINE_DIR/manifest.sh"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }

echo "============================================"
echo "  Loading Offline Bundle"
echo "============================================"
echo ""

# ============================================================
# 1. Detect Container Runtime
# ============================================================
info "--- Detecting Container Runtime ---"

RUNTIME=""
if command -v nerdctl &>/dev/null && nerdctl info &>/dev/null 2>&1; then
  RUNTIME="nerdctl"
elif command -v ctr &>/dev/null; then
  RUNTIME="ctr"
elif command -v docker &>/dev/null; then
  RUNTIME="docker"
elif command -v crictl &>/dev/null; then
  RUNTIME="crictl"
fi

if [ -z "$RUNTIME" ]; then
  error "No container runtime found (docker, nerdctl, ctr, crictl)"
  error "Cannot load images into the cluster"
  exit 1
fi
ok "Using runtime: $RUNTIME"
echo ""

# ============================================================
# 2. Load Container Images
# ============================================================
info "--- Loading Container Images ---"

IMAGE_FILE="$IMAGES_DIR/all-images.tar.gz"
if [ ! -f "$IMAGE_FILE" ]; then
  IMAGE_FILE="$IMAGES_DIR/all-images.tar"
fi

if [ ! -f "$IMAGE_FILE" ]; then
  error "Image bundle not found at $IMAGES_DIR/all-images.tar[.gz]"
  error "Run ./prepare-offline.sh first (while online)"
  exit 1
fi

info "Loading images from $(basename "$IMAGE_FILE")... (this may take a few minutes)"

case "$RUNTIME" in
  docker)
    if [[ "$IMAGE_FILE" == *.gz ]]; then
      gunzip -c "$IMAGE_FILE" | docker load
    else
      docker load -i "$IMAGE_FILE"
    fi
    ;;
  nerdctl)
    if [[ "$IMAGE_FILE" == *.gz ]]; then
      gunzip -c "$IMAGE_FILE" | nerdctl load
    else
      nerdctl load -i "$IMAGE_FILE"
    fi
    ;;
  ctr)
    # containerd - import into k8s.io namespace
    if [[ "$IMAGE_FILE" == *.gz ]]; then
      gunzip -c "$IMAGE_FILE" | ctr -n k8s.io images import -
    else
      ctr -n k8s.io images import "$IMAGE_FILE"
    fi
    ;;
  crictl)
    warn "crictl does not support direct image loading."
    warn "Attempting via ctr if available..."
    if command -v ctr &>/dev/null; then
      if [[ "$IMAGE_FILE" == *.gz ]]; then
        gunzip -c "$IMAGE_FILE" | ctr -n k8s.io images import -
      else
        ctr -n k8s.io images import "$IMAGE_FILE"
      fi
    else
      error "Cannot load images with crictl alone. Install ctr or docker."
      exit 1
    fi
    ;;
esac

ok "All images loaded"
echo ""

# ============================================================
# 3. Verify Images
# ============================================================
info "--- Verifying Images ---"
MISSING=0
for image in "${IMAGES[@]}"; do
  case "$RUNTIME" in
    docker)
      if docker image inspect "$image" &>/dev/null; then
        ok "  $image"
      else
        warn "  MISSING: $image"
        MISSING=$((MISSING + 1))
      fi
      ;;
    nerdctl)
      if nerdctl image inspect "$image" &>/dev/null; then
        ok "  $image"
      else
        warn "  MISSING: $image"
        MISSING=$((MISSING + 1))
      fi
      ;;
    ctr)
      if ctr -n k8s.io images check name=="$image" 2>/dev/null | grep -q "$image"; then
        ok "  $image"
      else
        warn "  MISSING: $image (may still work — ctr check is best effort)"
      fi
      ;;
    *)
      info "  Skipping verification for $RUNTIME"
      break
      ;;
  esac
done

if [ "$MISSING" -gt 0 ]; then
  warn "$MISSING image(s) could not be verified — pods may fail to start"
fi
echo ""

# ============================================================
# 4. Verify Helm Charts
# ============================================================
info "--- Verifying Helm Charts ---"
CHARTS_OK=true
for chart in ingress-nginx argo-cd harbor networktools; do
  if ls "$CHARTS_DIR"/${chart}-*.tgz &>/dev/null; then
    ok "  $(ls "$CHARTS_DIR"/${chart}-*.tgz | xargs -n1 basename)"
  else
    warn "  MISSING: $chart chart"
    CHARTS_OK=false
  fi
done
echo ""

# ============================================================
# Summary
# ============================================================
echo "============================================"
echo "  Offline Bundle Loaded!"
echo "============================================"
echo ""
echo "  Images and charts are ready."
echo "  Now run:  ./start.sh"
echo ""
echo "============================================"
