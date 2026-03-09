#!/usr/bin/env bash
set -euo pipefail

#============================================================================
#
#  Airgap Lab — Full End-to-End Installer
#
#  Combines all six steps into a single, modular script:
#    step1  – Install Nginx Ingress Controller + Harbor Registry
#    step2  – Configure Harbor (projects, Docker insecure registry)
#    step3  – Prepare ArgoCD images (pull, tag, push to Harbor)
#    step4  – Create bare Git repo with networktools Helm chart
#    step5  – Deploy ArgoCD offline from Harbor images
#    step6  – Create ArgoCD Application (GitOps auto-sync)
#
#  Usage:
#    ./full-install.sh              # run all steps
#    ./full-install.sh step3 step5  # run only specific steps
#
#============================================================================

# ─── Shared Variables ──────────────────────────────────────────────────────
BASE_DIR="/home/guy/devops/AirgapProject"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARBOR_NAMESPACE="harbor"
INGRESS_NAMESPACE="ingress-nginx"
HARBOR_HOST="harbor.local"
HARBOR_PORT="8080"
HARBOR_REGISTRY="${HARBOR_HOST}:${HARBOR_PORT}"
HARBOR_URL="http://${HARBOR_REGISTRY}"
HARBOR_API="${HARBOR_URL}/api/v2.0"
HARBOR_USER="admin"
HARBOR_PASS="Harbor12345"

ARGOCD_CHART="argo/argo-cd"
ARGOCD_NAMESPACE="argocd"
ARGOCD_HOSTNAME="argocd.local"

KIND_NODE="kind-control-plane"

BARE_REPO="${BASE_DIR}/repos/helm-charts.git"

NETTOOLS_IMAGE="wbitt/network-multitool"
NETTOOLS_TAG="latest"

# ─── Helpers ───────────────────────────────────────────────────────────────
banner() { printf '\n============================================\n %s\n============================================\n' "$1"; }

ensure_port_forward() {
  if ! curl -s -o /dev/null --max-time 3 "${HARBOR_URL}/"; then
    echo ">>> Starting port-forward..."
    pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
    sleep 1
    nohup kubectl port-forward -n "${INGRESS_NAMESPACE}" svc/ingress-nginx-controller \
      "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
    for i in $(seq 1 15); do
      curl -s -o /dev/null --max-time 2 "${HARBOR_URL}/" && break
      echo "  waiting for Harbor... (${i}/15)"; sleep 2
    done
  fi
}

# ─── Step 1: Install Nginx Ingress + Harbor ────────────────────────────────
step1() {
  banner "STEP 1 — Install Nginx Ingress Controller + Harbor"

  # Helm repos
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
  helm repo update

  # Ingress controller
  kubectl create namespace "${INGRESS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NAMESPACE}" \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.admissionWebhooks.enabled=false \
    --wait --timeout 120s

  kubectl wait --namespace "${INGRESS_NAMESPACE}" \
    --for=condition=Ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s

  # Harbor
  kubectl create namespace "${HARBOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install harbor harbor/harbor \
    --namespace "${HARBOR_NAMESPACE}" \
    --set expose.type=ingress \
    --set expose.ingress.className=nginx \
    --set "expose.ingress.hosts.core=${HARBOR_HOST}" \
    --set expose.tls.enabled=false \
    --set "externalURL=http://${HARBOR_HOST}" \
    --set "harborAdminPassword=${HARBOR_PASS}" \
    --set persistence.enabled=false \
    --wait --timeout 300s

  kubectl wait --namespace "${HARBOR_NAMESPACE}" \
    --for=condition=Ready pod --all \
    --timeout=300s

  echo ""
  echo "--- Ingress Controller Pods ---"
  kubectl get pods -n "${INGRESS_NAMESPACE}"
  echo ""
  echo "--- Harbor Pods ---"
  kubectl get pods -n "${HARBOR_NAMESPACE}"

  # Add harbor.local to host /etc/hosts if missing
  if ! grep -q "${HARBOR_HOST}" /etc/hosts; then
    echo "127.0.0.1  ${HARBOR_HOST}" | sudo tee -a /etc/hosts
    echo ">>> Added ${HARBOR_HOST} to /etc/hosts"
  fi

  echo ">>> Step 1 complete — Ingress + Harbor installed"
}

# ─── Step 2: Configure Harbor ──────────────────────────────────────────────
step2() {
  banner "STEP 2 — Configure Harbor"

  ensure_port_forward

  # Health check
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HARBOR_API}/health")
  if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "ERROR: Harbor health endpoint returned HTTP ${HTTP_CODE}"; exit 1
  fi
  echo ">>> Harbor health: OK"

  # Create projects
  create_harbor_project() {
    local name="$1" public="${2:-true}"
    local body
    body=$(curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" "${HARBOR_API}/projects?name=${name}")
    local exists
    exists=$(echo "${body}" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
print('true' if any(p['name'] == '${name}' for p in projects) else 'false')
" 2>/dev/null || echo "false")

    if [[ "${exists}" == "true" ]]; then
      echo ">>> Project '${name}' already exists"; return 0
    fi
    local resp
    resp=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "${HARBOR_USER}:${HARBOR_PASS}" \
      -X POST "${HARBOR_API}/projects" \
      -H "Content-Type: application/json" \
      -d "{\"project_name\": \"${name}\", \"public\": ${public}}")
    if [[ "${resp}" == "201" || "${resp}" == "409" ]]; then
      echo ">>> Project '${name}' ready"
    else
      echo "ERROR: Failed to create project '${name}' (HTTP ${resp})"; return 1
    fi
  }

  create_harbor_project "library" true
  create_harbor_project "argocd" true

  # Docker insecure registry
  DAEMON_JSON="/etc/docker/daemon.json"
  INSECURE_ENTRY="${HARBOR_REGISTRY}"

  local needs_restart=false
  if [[ -f "${DAEMON_JSON}" ]]; then
    if python3 -c "
import json
with open('${DAEMON_JSON}') as f: cfg = json.load(f)
exit(0 if '${INSECURE_ENTRY}' in cfg.get('insecure-registries', []) else 1)
" 2>/dev/null; then
      echo ">>> Docker already configured for ${INSECURE_ENTRY}"
    else
      python3 -c "
import json
with open('${DAEMON_JSON}') as f: cfg = json.load(f)
r = cfg.get('insecure-registries', [])
if '${INSECURE_ENTRY}' not in r: r.append('${INSECURE_ENTRY}')
cfg['insecure-registries'] = r
with open('${DAEMON_JSON}', 'w') as f: json.dump(cfg, f, indent=2)
"
      needs_restart=true
    fi
  else
    echo "{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}" | python3 -m json.tool | sudo tee "${DAEMON_JSON}" > /dev/null
    needs_restart=true
  fi

  if [[ "${needs_restart}" == "true" ]]; then
    sudo systemctl restart docker
    echo ">>> Docker daemon restarted"
    # Docker restart kills port-forward; restart it
    sleep 2
    ensure_port_forward
  fi

  # Docker login test
  echo "${HARBOR_PASS}" | docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" --password-stdin
  echo ">>> Step 2 complete — Harbor configured"
}

# ─── Step 3: Prepare ArgoCD Images ────────────────────────────────────────
step3() {
  banner "STEP 3 — Prepare ArgoCD Images"

  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update argo

  CHART_VERSION=$(helm search repo "${ARGOCD_CHART}" --output json | python3 -c "
import sys, json; print(json.load(sys.stdin)[0]['version'])")
  APP_VERSION=$(helm search repo "${ARGOCD_CHART}" --output json | python3 -c "
import sys, json; print(json.load(sys.stdin)[0]['app_version'])")
  echo ">>> Chart ${CHART_VERSION}  App ${APP_VERSION}"

  # Download chart .tgz for offline install (step 5)
  CHART_TGZ="${SCRIPT_DIR}/argo-cd-${CHART_VERSION}.tgz"
  if [[ ! -f "${CHART_TGZ}" ]]; then
    helm pull "${ARGOCD_CHART}" --version "${CHART_VERSION}" --destination "${SCRIPT_DIR}/"
    echo ">>> Chart saved: ${CHART_TGZ}"
  else
    echo ">>> Chart already saved: ${CHART_TGZ}"
  fi

  # Extract images
  IMAGES=$(helm template argocd "${ARGOCD_CHART}" \
    --namespace "${ARGOCD_NAMESPACE}" --version "${CHART_VERSION}" \
    2>/dev/null | grep -oP 'image:\s*\K\S+' | tr -d '"' | sort -u)

  echo ">>> Images to mirror:"
  echo "${IMAGES}"

  ensure_port_forward

  echo "${HARBOR_PASS}" | docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" --password-stdin

  echo "${IMAGES}" | while read -r src; do
    [[ -z "${src}" ]] && continue
    local_name=$(echo "${src}" | awk -F'/' '{print $NF}')
    target="${HARBOR_REGISTRY}/argocd/${local_name}"
    echo ">>> Mirroring ${src} -> ${target}"
    docker pull "${src}"
    docker tag  "${src}" "${target}"
    docker push "${target}"
  done

  # Save image list
  {
    echo "# ArgoCD images — chart ${CHART_VERSION} (app ${APP_VERSION})"
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "${IMAGES}" | while read -r img; do
      [[ -z "${img}" ]] && continue
      local_name=$(echo "${img}" | awk -F'/' '{print $NF}')
      echo "${img} -> ${HARBOR_REGISTRY}/argocd/${local_name}"
    done
  } > "${SCRIPT_DIR}/argocd-images.txt"

  echo ">>> Step 3 complete — ArgoCD images mirrored"
}

# ─── Step 4: Create Git Repo + Helm Chart ─────────────────────────────────
step4() {
  banner "STEP 4 — Create Git Repo + Helm Chart"

  ensure_port_forward
  echo "${HARBOR_PASS}" | docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" --password-stdin

  # Mirror network-multitool
  SOURCE="${NETTOOLS_IMAGE}:${NETTOOLS_TAG}"
  TARGET="${HARBOR_REGISTRY}/library/network-multitool:${NETTOOLS_TAG}"
  echo ">>> Mirroring ${SOURCE} -> ${TARGET}"
  docker pull "${SOURCE}"
  docker tag  "${SOURCE}" "${TARGET}"
  docker push "${TARGET}"

  # Bare repo
  mkdir -p "$(dirname "${BARE_REPO}")"
  if [[ -d "${BARE_REPO}" ]]; then
    rm -rf "${BARE_REPO}"
  fi
  git init --bare "${BARE_REPO}"
  git --git-dir="${BARE_REPO}" symbolic-ref HEAD refs/heads/main

  # Build chart in temp dir
  WORK_DIR=$(mktemp -d)
  CHART_DIR="${WORK_DIR}/helm-charts/networktools"
  mkdir -p "${CHART_DIR}/templates"

  cat > "${CHART_DIR}/Chart.yaml" << 'EOF'
apiVersion: v2
name: networktools
description: A network multitool application for testing and troubleshooting
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

  cat > "${CHART_DIR}/values.yaml" << EOF
replicaCount: 1

image:
  repository: ${HARBOR_REGISTRY}/library/network-multitool
  tag: "${NETTOOLS_TAG}"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  httpPort: 80
  httpsPort: 443

resources:
  limits:
    cpu: 200m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 64Mi

welcomeMessage: "Welcome to the Network Multitool - deployed by ArgoCD!"
EOF

  cat > "${CHART_DIR}/templates/deployment.yaml" << 'TMPL'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-networktools
  labels:
    app: {{ .Release.Name }}-networktools
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-networktools
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-networktools
    spec:
      containers:
        - name: networktools
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 80
            - name: https
              containerPort: 443
          env:
            - name: HTTP_PORT
              value: "80"
            - name: HTTPS_PORT
              value: "443"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: welcome-page
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
      volumes:
        - name: welcome-page
          configMap:
            name: {{ .Release.Name }}-welcome
TMPL

  cat > "${CHART_DIR}/templates/service.yaml" << 'TMPL'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-networktools
  labels:
    app: {{ .Release.Name }}-networktools
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.httpPort }}
      targetPort: http
      protocol: TCP
      name: http
    - port: {{ .Values.service.httpsPort }}
      targetPort: https
      protocol: TCP
      name: https
  selector:
    app: {{ .Release.Name }}-networktools
TMPL

  cat > "${CHART_DIR}/templates/configmap.yaml" << 'TMPL'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-welcome
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head><title>Network Multitool</title></head>
    <body>
      <h1>{{ .Values.welcomeMessage }}</h1>
      <p>Pod: {{ "{{ .Release.Name }}" }}-networktools</p>
      <p>Deployed via ArgoCD GitOps</p>
    </body>
    </html>
TMPL

  helm lint "${CHART_DIR}"

  # Push to bare repo
  cd "${WORK_DIR}/helm-charts"
  git init
  git checkout -b main
  git add .
  git commit -m "Initial commit: networktools Helm chart"
  git remote add origin "${BARE_REPO}"
  git push origin main

  rm -rf "${WORK_DIR}"
  echo ">>> Step 4 complete — Git repo + Helm chart created"
}

# ─── Step 5: Deploy ArgoCD Offline ────────────────────────────────────────
step5() {
  banner "STEP 5 — Deploy ArgoCD (Offline from Harbor)"

  # Locate chart tgz
  CHART_TGZ=$(ls "${SCRIPT_DIR}"/argo-cd-*.tgz 2>/dev/null | head -1)
  if [[ -z "${CHART_TGZ}" || ! -f "${CHART_TGZ}" ]]; then
    echo "ERROR: No argo-cd-*.tgz found in ${SCRIPT_DIR}. Run step 3 first."; exit 1
  fi
  echo ">>> Using chart: ${CHART_TGZ}"

  # Read image versions from the chart
  ARGOCD_TAG=$(helm show chart "${CHART_TGZ}" | grep '^appVersion' | awk '{print $2}')
  DEX_TAG=$(helm template argocd "${CHART_TGZ}" 2>/dev/null | grep -oP 'image:\s*\K\S+' | tr -d '"' | grep dex | head -1 | awk -F: '{print $NF}')
  REDIS_TAG=$(helm template argocd "${CHART_TGZ}" 2>/dev/null | grep -oP 'image:\s*\K\S+' | tr -d '"' | grep redis | head -1 | awk -F: '{print $NF}')

  ARGOCD_IMAGE="${HARBOR_REGISTRY}/argocd/argocd"
  DEX_IMAGE="${HARBOR_REGISTRY}/argocd/dex"
  REDIS_IMAGE="${HARBOR_REGISTRY}/argocd/redis"

  echo "  argocd : ${ARGOCD_IMAGE}:${ARGOCD_TAG}"
  echo "  dex    : ${DEX_IMAGE}:${DEX_TAG}"
  echo "  redis  : ${REDIS_IMAGE}:${REDIS_TAG}"

  ensure_port_forward

  # ── Kind node: DNS + containerd for Harbor ──
  GATEWAY_IP=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.20.0.1")

  if ! docker exec "${KIND_NODE}" grep -q "${HARBOR_HOST}" /etc/hosts 2>/dev/null; then
    docker exec "${KIND_NODE}" sh -c "echo '${GATEWAY_IP} ${HARBOR_HOST}' >> /etc/hosts"
    echo ">>> Added ${HARBOR_HOST} -> ${GATEWAY_IP} in Kind node /etc/hosts"
  fi

  if ! docker exec "${KIND_NODE}" test -f "/etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml" 2>/dev/null; then
    docker exec "${KIND_NODE}" mkdir -p "/etc/containerd/certs.d/${HARBOR_REGISTRY}"
    docker exec "${KIND_NODE}" sh -c "cat > /etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml << TOML
server = \"http://${HARBOR_REGISTRY}\"

[host.\"http://${HARBOR_REGISTRY}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
TOML"
    echo ">>> Created containerd hosts.toml for ${HARBOR_REGISTRY}"
  fi

  if ! docker exec "${KIND_NODE}" grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
    docker exec "${KIND_NODE}" sh -c 'cat >> /etc/containerd/config.toml << TOML

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
TOML'
    echo ">>> Added config_path to containerd. Restarting..."
    docker exec "${KIND_NODE}" systemctl restart containerd
    sleep 5
    pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
    sleep 1
    ensure_port_forward
  fi

  # Test pull from inside Kind
  docker exec "${KIND_NODE}" crictl pull "${ARGOCD_IMAGE}:${ARGOCD_TAG}" >/dev/null 2>&1
  echo ">>> Containerd pull test: OK"

  # Install git inside Kind node (needed for step 6)
  if ! docker exec "${KIND_NODE}" which git &>/dev/null; then
    docker exec "${KIND_NODE}" apt-get update -qq
    docker exec "${KIND_NODE}" apt-get install -y -qq git
    echo ">>> Installed git in Kind node"
  fi

  # ── Helm install ──
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
    --set "global.domain=${ARGOCD_HOSTNAME}" \
    --timeout 300s

  echo ">>> Waiting for ArgoCD rollouts..."
  for deploy in $(kubectl get deploy -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null); do
    kubectl rollout status "${deploy}" -n "${ARGOCD_NAMESPACE}" --timeout=300s
  done
  for sts in $(kubectl get statefulset -n "${ARGOCD_NAMESPACE}" -o name 2>/dev/null); do
    kubectl rollout status "${sts}" -n "${ARGOCD_NAMESPACE}" --timeout=300s
  done

  # Host /etc/hosts
  if ! grep -q "${ARGOCD_HOSTNAME}" /etc/hosts; then
    echo "127.0.0.1  ${ARGOCD_HOSTNAME}" | sudo tee -a /etc/hosts
  fi

  ARGOCD_PASS=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  echo ""
  echo "--- ArgoCD Pods ---"
  kubectl get pods -n "${ARGOCD_NAMESPACE}"
  echo ""
  echo ">>> ArgoCD admin password: ${ARGOCD_PASS}"
  echo ">>> Step 5 complete — ArgoCD deployed (all images from Harbor)"
}

# ─── Step 6: Create ArgoCD Application ────────────────────────────────────
step6() {
  banner "STEP 6 — Create ArgoCD Application"

  # Start git daemon
  touch "${BARE_REPO}/git-daemon-export-ok"
  pkill -f "git daemon" 2>/dev/null || true
  sleep 1
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

  GATEWAY_IP=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.20.0.1")
  GIT_REPO_URL="git://${GATEWAY_IP}/helm-charts.git"

  # Verify from Kind node
  docker exec "${KIND_NODE}" rm -rf /tmp/test-clone 2>/dev/null || true
  docker exec "${KIND_NODE}" git clone "${GIT_REPO_URL}" /tmp/test-clone 2>&1
  docker exec "${KIND_NODE}" ls /tmp/test-clone/networktools/Chart.yaml
  docker exec "${KIND_NODE}" rm -rf /tmp/test-clone
  echo ">>> Git repo reachable from cluster"

  ensure_port_forward

  # Application manifest
  APP_MANIFEST="${SCRIPT_DIR}/argocd-application.yaml"
  cat > "${APP_MANIFEST}" << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: networktools
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: main
    path: networktools
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

  kubectl apply -f "${APP_MANIFEST}"
  echo ">>> Application 'networktools' created — waiting for sync..."

  for i in $(seq 1 30); do
    HEALTH=$(kubectl get application networktools -n "${ARGOCD_NAMESPACE}" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    SYNC=$(kubectl get application networktools -n "${ARGOCD_NAMESPACE}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    echo "  [${i}/30] Sync: ${SYNC} | Health: ${HEALTH}"
    if [[ "${SYNC}" == "Synced" && "${HEALTH}" == "Healthy" ]]; then
      echo ">>> Application is Synced and Healthy!"; break
    fi
    sleep 5
  done

  echo ""
  kubectl get pods -n default -l "app=networktools-networktools" 2>/dev/null || \
    kubectl get pods -n default 2>/dev/null | grep -i networktools || true

  echo ">>> Step 6 complete — ArgoCD Application deployed via GitOps"
}

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
  echo "╔════════════════════════════════════════════╗"
  echo "║   Airgap Lab — Full End-to-End Installer   ║"
  echo "╚════════════════════════════════════════════╝"
  echo ""

  local steps=("$@")
  if [[ ${#steps[@]} -eq 0 ]]; then
    steps=(step1 step2 step3 step4 step5 step6)
  fi

  for s in "${steps[@]}"; do
    case "${s}" in
      step1|1) step1 ;;
      step2|2) step2 ;;
      step3|3) step3 ;;
      step4|4) step4 ;;
      step5|5) step5 ;;
      step6|6) step6 ;;
      *) echo "Unknown step: ${s}. Use step1..step6 or 1..6"; exit 1 ;;
    esac
  done

  banner "ALL DONE"
  ARGOCD_PASS=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "(run step5 first)")
  echo ""
  echo "Harbor URL:      ${HARBOR_URL}"
  echo "Harbor Admin:    ${HARBOR_USER} / ${HARBOR_PASS}"
  echo ""
  echo "ArgoCD URL:      http://${ARGOCD_HOSTNAME}:${HARBOR_PORT}"
  echo "ArgoCD Admin:    admin / ${ARGOCD_PASS}"
  echo ""
  echo "Git Repo:        ${BARE_REPO}"
  echo "GitOps App:      networktools (auto-sync enabled)"
  echo ""
}

main "$@"
