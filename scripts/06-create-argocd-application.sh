#!/usr/bin/env bash
set -euo pipefail

#============================================================================
# 06 - Create an ArgoCD Application to Deploy the Helm Chart
#
# Starts a Git server to expose the local bare repo to ArgoCD,
# registers the repo with ArgoCD, and creates an Application CR
# with automated sync, self-heal, and prune enabled.
#============================================================================

BASE_DIR="/home/guy/devops/AirgapProject"
BARE_REPO="${BASE_DIR}/repos/helm-charts.git"
ARGOCD_NAMESPACE="argocd"
APP_NAME="networktools"
APP_NAMESPACE="default"
CHART_PATH="networktools"
TARGET_REVISION="main"
HARBOR_PORT="8080"

echo "============================================"
echo " Step 1: Start Git daemon for repo access"
echo "============================================"

# ArgoCD runs inside the cluster and can't access host filesystem directly.
# We use git daemon to serve the bare repo over git:// protocol.

# Enable git-daemon-export on the repo
touch "${BARE_REPO}/git-daemon-export-ok"

# Kill any existing git daemon
pkill -f "git daemon" 2>/dev/null || true
sleep 1

# Start git daemon listening on all interfaces, port 9418
git daemon \
  --reuseaddr \
  --base-path="${BASE_DIR}/repos" \
  --export-all \
  --enable=receive-pack \
  --listen=0.0.0.0 \
  --port=9418 \
  --detach \
  "${BASE_DIR}/repos"

echo ">>> Git daemon started on port 9418"

# Get the Docker gateway IP (how the Kind node reaches the host)
GATEWAY_IP=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.20.0.1")

# Verify git clone works from the Kind node
echo ">>> Testing git access from Kind node..."
docker exec kind-control-plane rm -rf /tmp/test-clone 2>/dev/null || true
docker exec kind-control-plane git clone "git://${GATEWAY_IP}/helm-charts.git" /tmp/test-clone 2>&1
docker exec kind-control-plane ls /tmp/test-clone/networktools/Chart.yaml
docker exec kind-control-plane rm -rf /tmp/test-clone
echo ">>> Git repo accessible from cluster at git://${GATEWAY_IP}/helm-charts.git"

GIT_REPO_URL="git://${GATEWAY_IP}/helm-charts.git"

echo ""
echo "============================================"
echo " Step 2: Ensure port-forward is active"
echo "============================================"

if ! curl -s -o /dev/null --max-time 3 "http://harbor.local:${HARBOR_PORT}/"; then
  echo ">>> Starting port-forward..."
  pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
  for i in $(seq 1 10); do
    curl -s -o /dev/null --max-time 2 "http://harbor.local:${HARBOR_PORT}/" && break
    sleep 2
  done
fi
echo ">>> Port-forward active"

echo ""
echo "============================================"
echo " Step 3: Create ArgoCD Application manifest"
echo "============================================"

APP_MANIFEST="${BASE_DIR}/scripts/argocd-application.yaml"

cat > "${APP_MANIFEST}" << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: ${CHART_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo ">>> Application manifest created: ${APP_MANIFEST}"
echo ""
cat "${APP_MANIFEST}"

echo ""
echo "============================================"
echo " Step 4: Apply ArgoCD Application"
echo "============================================"

kubectl apply -f "${APP_MANIFEST}"
echo ">>> Application '${APP_NAME}' created"

echo ""
echo "============================================"
echo " Step 5: Wait for sync"
echo "============================================"

echo ">>> Waiting for ArgoCD to sync the application..."
for i in $(seq 1 30); do
  HEALTH=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  SYNC=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  echo "  [${i}/30] Sync: ${SYNC} | Health: ${HEALTH}"

  if [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
    echo ">>> Application is Synced and Healthy!"
    break
  fi
  sleep 5
done

echo ""
echo "============================================"
echo " Step 6: Verify deployment"
echo "============================================"

echo "--- ArgoCD Application ---"
kubectl get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE}"

echo ""
echo "--- Deployed Resources ---"
kubectl get deployment,service,configmap -l "app=${APP_NAME}-networktools" -n "${APP_NAMESPACE}" 2>/dev/null || \
kubectl get all -n "${APP_NAMESPACE}" 2>/dev/null | grep -i networktools || true

echo ""
echo "--- Pods ---"
kubectl get pods -n "${APP_NAMESPACE}" -l "app=${APP_NAME}-networktools" 2>/dev/null || \
kubectl get pods -n "${APP_NAMESPACE}" 2>/dev/null | grep -i networktools || true

echo ""
echo "--- Pod Images ---"
kubectl get pods -n "${APP_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep network || true

echo ""
echo "============================================"
echo " Done!"
echo "============================================"
echo ""
echo "Application '${APP_NAME}' deployed via ArgoCD GitOps"
echo "  Git repo:      ${GIT_REPO_URL}"
echo "  Chart path:    ${CHART_PATH}"
echo "  Branch:        ${TARGET_REVISION}"
echo "  Namespace:     ${APP_NAMESPACE}"
echo "  Auto-sync:     enabled (prune + selfHeal)"
echo ""
echo "ArgoCD UI:       http://argocd.local:${HARBOR_PORT}"
echo ""
echo "To test GitOps, push a change to the repo and watch ArgoCD auto-sync:"
echo "  git clone ${BARE_REPO} /tmp/helm-edit"
echo "  cd /tmp/helm-edit"
echo "  # edit networktools/values.yaml (e.g. change replicaCount)"
echo "  git commit -am 'Update replicas' && git push"
