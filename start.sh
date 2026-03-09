#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$SCRIPT_DIR/offline"
CHARTS_DIR="$OFFLINE_DIR/charts"
INGRESS_PORT="${INGRESS_PORT:-8080}"

# Source manifest for chart versions (if available)
if [ -f "$OFFLINE_DIR/manifest.sh" ]; then
  source "$OFFLINE_DIR/manifest.sh"
fi

# ---- Helper functions ----
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
ok()    { echo "[OK]    $*"; }

wait_for_namespace() {
  local ns="$1"
  if ! kubectl get namespace "$ns" &>/dev/null; then
    info "Creating namespace: $ns"
    kubectl create namespace "$ns"
  fi
}

wait_for_rollout() {
  local ns="$1" deploy="$2" timeout="${3:-120}"
  info "Waiting for $deploy in $ns to be ready..."
  kubectl rollout status deployment/"$deploy" -n "$ns" --timeout="${timeout}s" 2>/dev/null || \
    warn "$deploy not fully ready yet — continuing"
}

# ---- Detect offline mode ----
OFFLINE=false
if ls "$CHARTS_DIR"/*.tgz &>/dev/null 2>&1; then
  OFFLINE=true
fi

echo "============================================"
echo "  AirgapProject - Full Stack Launcher"
if [ "$OFFLINE" = true ]; then
echo "  Mode: OFFLINE (using local charts/images)"
else
echo "  Mode: ONLINE"
fi
echo "============================================"
echo ""

# ---- Pre-flight checks ----
for cmd in helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd is required but not found in PATH"
    exit 1
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  error "Cannot connect to Kubernetes cluster"
  exit 1
fi
ok "Cluster connection verified"
echo ""

# ============================================================
# 1. NGINX Ingress Controller
# ============================================================
info "--- Ingress Controller ---"
if kubectl get deployment ingress-nginx-controller -n ingress-nginx &>/dev/null; then
  ok "ingress-nginx already running"
else
  wait_for_namespace ingress-nginx
  if [ "$OFFLINE" = true ]; then
    INGRESS_CHART=$(ls "$CHARTS_DIR"/ingress-nginx-*.tgz 2>/dev/null | head -1)
    info "Installing ingress-nginx from local chart..."
    helm upgrade --install ingress-nginx "$INGRESS_CHART" \
      --namespace ingress-nginx \
      --set controller.service.type=ClusterIP \
      --set controller.admissionWebhooks.enabled=false \
      --wait --timeout 5m
  else
    info "Adding ingress-nginx Helm repo..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx
    info "Installing ingress-nginx..."
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --set controller.service.type=ClusterIP \
      --set controller.admissionWebhooks.enabled=false \
      --wait --timeout 5m
  fi
  ok "ingress-nginx installed"
fi
echo ""

# ============================================================
# 2. ArgoCD
# ============================================================
info "--- ArgoCD ---"
if kubectl get deployment argocd-server -n argocd &>/dev/null; then
  ok "ArgoCD already deployed"
  # Ensure ingress exists
  if ! kubectl get ingress -n argocd 2>/dev/null | grep -q argocd; then
    info "Creating ArgoCD ingress..."
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
    ok "ArgoCD ingress created"
  else
    ok "ArgoCD ingress already exists"
  fi
else
  wait_for_namespace argocd
  if [ "$OFFLINE" = true ]; then
    ARGOCD_CHART=$(ls "$CHARTS_DIR"/argo-cd-*.tgz 2>/dev/null | head -1)
    info "Installing ArgoCD from local chart..."
    helm upgrade --install argocd "$ARGOCD_CHART" \
      --namespace argocd \
      --values "$SCRIPT_DIR/argocd-values.yaml" \
      --wait --timeout 5m
  else
    info "Adding ArgoCD Helm repo..."
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update argo
    info "Installing ArgoCD via Helm..."
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      --values "$SCRIPT_DIR/argocd-values.yaml" \
      --wait --timeout 5m
  fi
  ok "ArgoCD installed"
fi
wait_for_rollout argocd argocd-server 120
echo ""

# ============================================================
# 3. Harbor
# ============================================================
info "--- Harbor ---"
if kubectl get deployment harbor-core -n harbor &>/dev/null; then
  ok "Harbor already deployed"
  # Ensure ingress exists
  if ! kubectl get ingress -n harbor 2>/dev/null | grep -q harbor; then
    info "Creating Harbor ingress..."
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: harbor-ingress
  namespace: harbor
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
    - host: harbor.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: harbor-portal
                port:
                  number: 80
          - path: /api/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /service/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /v2/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /chartrepo/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /c/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
EOF
    ok "Harbor ingress created"
  else
    ok "Harbor ingress already exists"
  fi
else
  wait_for_namespace harbor
  if [ "$OFFLINE" = true ]; then
    HARBOR_CHART=$(ls "$CHARTS_DIR"/harbor-*.tgz 2>/dev/null | head -1)
    info "Installing Harbor from local chart..."
    helm upgrade --install harbor "$HARBOR_CHART" \
      --namespace harbor \
      --values "$SCRIPT_DIR/harbor-values.yaml" \
      --wait --timeout 10m
  else
    info "Adding Harbor Helm repo..."
    helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
    helm repo update harbor
    info "Installing Harbor via Helm..."
    helm upgrade --install harbor harbor/harbor \
      --namespace harbor \
      --values "$SCRIPT_DIR/harbor-values.yaml" \
      --wait --timeout 10m
  fi
  ok "Harbor installed"
fi
wait_for_rollout harbor harbor-core 120
echo ""

# ============================================================
# 4. Network Tools (Helm chart)
# ============================================================
info "--- Network Tools ---"
wait_for_namespace networktools
if [ "$OFFLINE" = true ]; then
  NT_CHART=$(ls "$CHARTS_DIR"/networktools-*.tgz 2>/dev/null | head -1)
  if [ -n "$NT_CHART" ]; then
    info "Installing networktools from local chart..."
    helm upgrade --install networktools "$NT_CHART" \
      --namespace networktools \
      --wait --timeout 2m
  else
    info "Installing networktools from source chart..."
    helm upgrade --install networktools "$SCRIPT_DIR/networktools" \
      --namespace networktools \
      --wait --timeout 2m
  fi
else
  info "Installing/upgrading networktools chart..."
  helm upgrade --install networktools "$SCRIPT_DIR/networktools" \
    --namespace networktools \
    --wait --timeout 2m
fi
ok "networktools deployed"
echo ""

# ============================================================
# 5. /etc/hosts entries
# ============================================================
info "--- Hosts File ---"
HOSTS_CHANGED=false
for host in argocd.local harbor.local; do
  if ! grep -q "$host" /etc/hosts 2>/dev/null; then
    info "Adding $host to /etc/hosts (requires sudo)..."
    echo "127.0.0.1  $host" | sudo tee -a /etc/hosts >/dev/null
    HOSTS_CHANGED=true
  fi
done
if [ "$HOSTS_CHANGED" = true ]; then
  ok "Hosts entries added"
else
  ok "Hosts entries already present"
fi
echo ""

# ============================================================
# 6. Port-forward ingress to localhost:8080
# ============================================================
info "--- Ingress Port Forward (port $INGRESS_PORT) ---"
# Kill any existing port-forward on the same port
if pgrep -f "port-forward.*$INGRESS_PORT:80" &>/dev/null; then
  ok "Port-forward already running on port $INGRESS_PORT"
else
  if ss -tlnp sport = :"$INGRESS_PORT" 2>/dev/null | grep -q LISTEN; then
    ok "Port $INGRESS_PORT already in use (likely ingress is already forwarded)"
  else
    info "Starting port-forward: localhost:$INGRESS_PORT -> ingress-nginx..."
    nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "$INGRESS_PORT":80 \
      --address 0.0.0.0 >/dev/null 2>&1 &
    sleep 2
    ok "Port-forward started (PID: $!)"
  fi
fi
echo ""

# ============================================================
# 7. Health Checks
# ============================================================
info "--- Health Checks ---"
sleep 1
ARGO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: argocd.local" "http://localhost:$INGRESS_PORT/" 2>/dev/null || echo "000")
HARBOR_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: harbor.local" "http://localhost:$INGRESS_PORT/" 2>/dev/null || echo "000")

if [ "$ARGO_STATUS" = "200" ]; then
  ok "ArgoCD responding (HTTP $ARGO_STATUS)"
else
  warn "ArgoCD returned HTTP $ARGO_STATUS"
fi

if [ "$HARBOR_STATUS" = "200" ]; then
  ok "Harbor responding (HTTP $HARBOR_STATUS)"
else
  warn "Harbor returned HTTP $HARBOR_STATUS"
fi
echo ""

# ============================================================
# Summary & Credentials
# ============================================================
echo "============================================"
echo "  All Services Running!"
echo "============================================"
echo ""
echo "  ArgoCD:        http://argocd.local:$INGRESS_PORT"
echo "  Harbor:        http://harbor.local:$INGRESS_PORT"
echo "  Network Tools: kubectl exec -it deploy/networktools -n networktools -- bash"
echo ""
echo "  --- Credentials ---"
echo ""
echo "  ArgoCD:"
echo "    Username: admin"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || true
if [ -n "${ARGOCD_PASS:-}" ]; then
  echo "    Password: $ARGOCD_PASS"
else
  echo "    Password: (initial admin secret not found)"
fi
echo ""
echo "  Harbor:"
echo "    Username: admin"
HARBOR_PASS=$(kubectl -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null) || true
if [ -n "${HARBOR_PASS:-}" ]; then
  echo "    Password: $HARBOR_PASS"
else
  echo "    Password: Harbor12345 (default)"
fi
echo ""
echo "============================================"
