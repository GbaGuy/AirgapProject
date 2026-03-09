#!/usr/bin/env bash
set -euo pipefail

#============================================================================
# 05 - Deploy ArgoCD (Offline Install Using Harbor)
#
# Installs ArgoCD from a local Helm chart .tgz with all images pulled from
# the Harbor registry - simulating a fully airgapped deployment.
# Exposes ArgoCD via Ingress on argocd.local.
#============================================================================

HARBOR_HOST="harbor.local"
HARBOR_PORT="8080"
HARBOR_REGISTRY="${HARBOR_HOST}:${HARBOR_PORT}"
HARBOR_URL="http://${HARBOR_REGISTRY}"

ARGOCD_NAMESPACE="argocd"
ARGOCD_HOSTNAME="argocd.local"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_TGZ="${SCRIPT_DIR}/argo-cd-9.4.9.tgz"

# Image references in Harbor (mirrored in step 03)
ARGOCD_IMAGE="${HARBOR_REGISTRY}/argocd/argocd"
ARGOCD_TAG="v3.3.2"
DEX_IMAGE="${HARBOR_REGISTRY}/argocd/dex"
DEX_TAG="v2.45.1"
REDIS_IMAGE="${HARBOR_REGISTRY}/argocd/redis"
REDIS_TAG="8.2.3-alpine"

echo "============================================"
echo " Step 1: Verify prerequisites"
echo "============================================"

# Check chart file exists
if [[ ! -f "${CHART_TGZ}" ]]; then
  echo "ERROR: Chart not found at ${CHART_TGZ}"
  echo "Run 03-prepare-argocd-images.sh first, or download with:"
  echo "  helm pull argo/argo-cd --destination ${SCRIPT_DIR}/"
  exit 1
fi
echo ">>> Chart file: ${CHART_TGZ}"

# Ensure port-forward is active
if ! curl -s -o /dev/null --max-time 3 "${HARBOR_URL}/"; then
  echo ">>> Starting port-forward..."
  pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
  for i in $(seq 1 15); do
    curl -s -o /dev/null --max-time 2 "${HARBOR_URL}/" && break
    echo "  waiting for Harbor... (${i}/15)"; sleep 2
  done
fi

# Verify all images exist in Harbor
echo ">>> Checking images in Harbor..."
for img in "argocd/argocd" "argocd/dex" "argocd/redis"; do
  COUNT=$(curl -s -u admin:Harbor12345 \
    "${HARBOR_URL}/api/v2.0/projects/argocd/repositories" | \
    python3 -c "
import sys, json
repos = json.load(sys.stdin)
print(sum(1 for r in repos if r['name'] == '${img}'))
" 2>/dev/null)
  if [[ "${COUNT}" == "0" ]]; then
    echo "ERROR: Image '${img}' not found in Harbor. Run 03-prepare-argocd-images.sh first."
    exit 1
  fi
  echo "    ${img} OK"
done

echo ""
echo "============================================"
echo " Step 1b: Configure Kind node for Harbor"
echo "============================================"
# Kind nodes cannot resolve harbor.local by default.
# We add it to /etc/hosts pointing at the Docker gateway (host machine),
# and configure containerd to use HTTP for Harbor.

KIND_NODE="kind-control-plane"
GATEWAY_IP=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.20.0.1")

if ! docker exec "${KIND_NODE}" grep -q "${HARBOR_HOST}" /etc/hosts 2>/dev/null; then
  docker exec "${KIND_NODE}" sh -c "echo '${GATEWAY_IP} ${HARBOR_HOST}' >> /etc/hosts"
  echo ">>> Added ${HARBOR_HOST} -> ${GATEWAY_IP} in Kind node /etc/hosts"
else
  echo ">>> ${HARBOR_HOST} already in Kind node /etc/hosts"
fi

# Configure containerd to use HTTP for harbor.local:8080
if ! docker exec "${KIND_NODE}" test -f "/etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml" 2>/dev/null; then
  docker exec "${KIND_NODE}" mkdir -p "/etc/containerd/certs.d/${HARBOR_REGISTRY}"
  docker exec "${KIND_NODE}" sh -c "cat > /etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml << TOML
server = \"http://${HARBOR_REGISTRY}\"

[host.\"http://${HARBOR_REGISTRY}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
TOML"
  echo ">>> Created containerd hosts.toml for ${HARBOR_REGISTRY}"
else
  echo ">>> Containerd hosts.toml already configured"
fi

# Ensure containerd config_path is set for certs.d
if ! docker exec "${KIND_NODE}" grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
  docker exec "${KIND_NODE}" sh -c 'cat >> /etc/containerd/config.toml << TOML

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
TOML'
  echo ">>> Added registry config_path to containerd. Restarting..."
  docker exec "${KIND_NODE}" systemctl restart containerd
  sleep 5
  echo ">>> Containerd restarted"
  # Re-establish port-forward after containerd restart
  pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
  for i in $(seq 1 10); do
    curl -s -o /dev/null --max-time 2 "${HARBOR_URL}/" && break
    sleep 2
  done
else
  echo ">>> Containerd config_path already set"
fi

# Verify containerd can pull from Harbor
echo ">>> Testing containerd pull from Harbor..."
docker exec "${KIND_NODE}" crictl pull "${ARGOCD_IMAGE}:${ARGOCD_TAG}" >/dev/null 2>&1
echo "    Pull test: OK"

echo ""
echo "============================================"
echo " Step 2: Verify image overrides"
echo "============================================"

echo ">>> Rendering chart to verify all images point to Harbor..."
RENDERED_IMAGES=$(helm template argocd "${CHART_TGZ}" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --set global.image.repository="${ARGOCD_IMAGE}" \
  --set global.image.tag="${ARGOCD_TAG}" \
  --set dex.image.repository="${DEX_IMAGE}" \
  --set dex.image.tag="${DEX_TAG}" \
  --set redis.image.repository="${REDIS_IMAGE}" \
  --set redis.image.tag="${REDIS_TAG}" \
  2>/dev/null | grep -oP 'image:\s*\K\S+' | tr -d '"' | sort -u)

echo "    Images that will be used:"
echo "${RENDERED_IMAGES}" | while read -r img; do
  echo "      ${img}"
done

# Verify no external images leak through
EXTERNAL=$(echo "${RENDERED_IMAGES}" | grep -v "${HARBOR_REGISTRY}" || true)
if [[ -n "${EXTERNAL}" ]]; then
  echo "WARNING: Some images still reference external registries:"
  echo "${EXTERNAL}"
fi

echo ""
echo "============================================"
echo " Step 3: Install ArgoCD from local chart"
echo "============================================"

kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd "${CHART_TGZ}" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --set global.image.repository="${ARGOCD_IMAGE}" \
  --set global.image.tag="${ARGOCD_TAG}" \
  --set global.image.imagePullPolicy=IfNotPresent \
  --set dex.image.repository="${DEX_IMAGE}" \
  --set dex.image.tag="${DEX_TAG}" \
  --set redis.image.repository="${REDIS_IMAGE}" \
  --set redis.image.tag="${REDIS_TAG}" \
  --set server.insecure=true \
  --set server.ingress.enabled=true \
  --set server.ingress.ingressClassName=nginx \
  --set "server.ingress.hosts[0]=${ARGOCD_HOSTNAME}" \
  --set global.domain="${ARGOCD_HOSTNAME}" \
  --wait --timeout 300s

echo ""
echo "============================================"
echo " Step 4: Wait for all pods"
echo "============================================"

echo ">>> Waiting for ArgoCD pods to be ready..."
kubectl wait --namespace "${ARGOCD_NAMESPACE}" \
  --for=condition=Ready pod --all \
  --timeout=300s

echo ""
echo "--- ArgoCD Pods ---"
kubectl get pods -n "${ARGOCD_NAMESPACE}"

echo ""
echo "--- Verify images are from Harbor ---"
kubectl get pods -n "${ARGOCD_NAMESPACE}" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u

echo ""
echo "============================================"
echo " Step 5: Configure access"
echo "============================================"

# Add argocd.local to /etc/hosts if not present
if ! grep -q "${ARGOCD_HOSTNAME}" /etc/hosts; then
  echo "127.0.0.1  ${ARGOCD_HOSTNAME}" | sudo tee -a /etc/hosts
  echo ">>> Added ${ARGOCD_HOSTNAME} to /etc/hosts"
else
  echo ">>> ${ARGOCD_HOSTNAME} already in /etc/hosts"
fi

echo ""
echo "--- Ingress ---"
kubectl get ingress -n "${ARGOCD_NAMESPACE}"

echo ""
echo "============================================"
echo " Step 6: Retrieve admin password"
echo "============================================"

ARGOCD_PASS=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ">>> ArgoCD admin password: ${ARGOCD_PASS}"

echo ""
echo "============================================"
echo " Step 7: Test ArgoCD access"
echo "============================================"

# Test through ingress
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${ARGOCD_HOSTNAME}:${HARBOR_PORT}/")
echo ">>> ArgoCD HTTP response: ${HTTP_CODE}"

echo ""
echo "============================================"
echo " Deployment Complete!"
echo "============================================"
echo ""
echo "ArgoCD URL:     http://${ARGOCD_HOSTNAME}:${HARBOR_PORT}"
echo "Username:       admin"
echo "Password:       ${ARGOCD_PASS}"
echo ""
echo "All images served from Harbor (airgap-ready):"
echo "  ${ARGOCD_IMAGE}:${ARGOCD_TAG}"
echo "  ${DEX_IMAGE}:${DEX_TAG}"
echo "  ${REDIS_IMAGE}:${REDIS_TAG}"
