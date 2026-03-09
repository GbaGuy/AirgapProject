#!/usr/bin/env bash
set -euo pipefail

#============================================================================
# 03 - Prepare ArgoCD Images for Airgap Install
#
# Uses helm template to discover all images needed by the ArgoCD Helm chart,
# then pulls, re-tags, and pushes them to the local Harbor registry.
# This ensures a fully offline ArgoCD installation is possible.
#============================================================================

HARBOR_HOST="harbor.local"
HARBOR_PORT="8080"
HARBOR_REGISTRY="${HARBOR_HOST}:${HARBOR_PORT}"
HARBOR_PROJECT="argocd"
HARBOR_USER="admin"
HARBOR_PASS="Harbor12345"
HARBOR_URL="http://${HARBOR_REGISTRY}"

ARGOCD_CHART="argo/argo-cd"
ARGOCD_NAMESPACE="argocd"

echo "============================================"
echo " Step 1: Ensure Helm repo is available"
echo "============================================"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

CHART_VERSION=$(helm search repo "${ARGOCD_CHART}" --output json | python3 -c "
import sys, json
charts = json.load(sys.stdin)
print(charts[0]['version'])
")
APP_VERSION=$(helm search repo "${ARGOCD_CHART}" --output json | python3 -c "
import sys, json
charts = json.load(sys.stdin)
print(charts[0]['app_version'])
")

echo ">>> Chart version: ${CHART_VERSION}"
echo ">>> App version:   ${APP_VERSION}"

echo ""
echo "============================================"
echo " Step 2: Extract images from Helm template"
echo "============================================"

IMAGES=$(helm template argocd "${ARGOCD_CHART}" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --version "${CHART_VERSION}" \
  2>/dev/null | grep -oP 'image:\s*\K\S+' | tr -d '"' | sort -u)

echo ">>> Found images:"
echo "${IMAGES}" | while read -r img; do
  echo "    ${img}"
done

echo ""
echo "============================================"
echo " Step 3: Verify Harbor connectivity"
echo "============================================"

# Ensure port-forward is active
if ! curl -s -o /dev/null --max-time 3 "${HARBOR_URL}/"; then
  echo ">>> Port-forward not active. Starting it..."
  pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
  for i in $(seq 1 15); do
    if curl -s -o /dev/null --max-time 2 "${HARBOR_URL}/"; then break; fi
    echo "  waiting for Harbor... (${i}/15)"
    sleep 2
  done
fi

HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${HARBOR_URL}/api/v2.0/health")
if [[ "${HEALTH}" != "200" ]]; then
  echo "ERROR: Harbor is not healthy (HTTP ${HEALTH})"
  exit 1
fi
echo ">>> Harbor health check: OK"

echo ""
echo "============================================"
echo " Step 4: Docker login to Harbor"
echo "============================================"
echo "${HARBOR_PASS}" | docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" --password-stdin
echo ""

echo "============================================"
echo " Step 5: Pull, tag, and push images"
echo "============================================"

FAILED=()

echo "${IMAGES}" | while read -r SOURCE_IMAGE; do
  [[ -z "${SOURCE_IMAGE}" ]] && continue

  # Derive the target image name:
  # e.g. quay.io/argoproj/argocd:v3.3.2 -> harbor.local:8080/argocd/argocd:v3.3.2
  # e.g. ecr-public.aws.com/docker/library/redis:8.2.3 -> harbor.local:8080/argocd/redis:8.2.3
  IMAGE_NAME_TAG=$(echo "${SOURCE_IMAGE}" | awk -F'/' '{print $NF}')
  TARGET_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME_TAG}"

  echo ""
  echo "--- Mirroring: ${SOURCE_IMAGE}"
  echo "    Target:    ${TARGET_IMAGE}"

  echo "  [1/3] Pulling..."
  if ! docker pull "${SOURCE_IMAGE}"; then
    echo "  ERROR: Failed to pull ${SOURCE_IMAGE}"
    FAILED+=("${SOURCE_IMAGE}")
    continue
  fi

  echo "  [2/3] Tagging..."
  docker tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}"

  echo "  [3/3] Pushing..."
  if ! docker push "${TARGET_IMAGE}"; then
    echo "  ERROR: Failed to push ${TARGET_IMAGE}"
    FAILED+=("${TARGET_IMAGE}")
    continue
  fi

  echo "  >>> Done: ${TARGET_IMAGE}"
done

echo ""
echo "============================================"
echo " Step 6: Verify images in Harbor"
echo "============================================"

REPOS=$(curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" \
  "${HARBOR_URL}/api/v2.0/projects/${HARBOR_PROJECT}/repositories" | \
  python3 -c "
import sys, json
repos = json.load(sys.stdin)
if not repos:
    print('  (no repositories found)')
else:
    for r in repos:
        print(f\"  {r['name']:<40} artifacts: {r['artifact_count']}\")
" 2>/dev/null)

echo "--- Harbor '${HARBOR_PROJECT}' project repositories ---"
echo "${REPOS}"

echo ""
echo "============================================"
echo " Step 7: Save image list for offline use"
echo "============================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_LIST="${SCRIPT_DIR}/argocd-images.txt"

{
  echo "# ArgoCD images for airgap installation"
  echo "# Chart: ${ARGOCD_CHART} version ${CHART_VERSION} (app ${APP_VERSION})"
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "#"
  echo "# Format: SOURCE_IMAGE -> TARGET_IMAGE"
  echo "${IMAGES}" | while read -r img; do
    [[ -z "${img}" ]] && continue
    name_tag=$(echo "${img}" | awk -F'/' '{print $NF}')
    echo "${img} -> ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${name_tag}"
  done
} > "${IMAGE_LIST}"

echo ">>> Image list saved to: ${IMAGE_LIST}"
cat "${IMAGE_LIST}"

echo ""
echo "============================================"
echo " Preparation Complete!"
echo "============================================"
echo ""
echo "All ArgoCD images have been mirrored to Harbor."
echo "Registry:  ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/"
echo ""
echo "Next step: Install ArgoCD using these local images"
echo "  helm upgrade --install argocd argo/argo-cd \\"
echo "    --namespace argocd --create-namespace \\"
echo "    --set global.image.repository=${HARBOR_REGISTRY}/${HARBOR_PROJECT}/argocd \\"
echo "    --set redis.image.repository=${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis \\"
echo "    --set dex.image.repository=${HARBOR_REGISTRY}/${HARBOR_PROJECT}/dex"
