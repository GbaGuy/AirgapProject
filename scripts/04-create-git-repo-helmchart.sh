#!/usr/bin/env bash
set -euo pipefail

#============================================================================
# 04 - Create a Git Repository with a Helm Chart
#
# Creates a local bare Git repository containing a Helm chart that deploys
# a network-multitool application. ArgoCD will use this as its GitOps source.
#============================================================================

BASE_DIR="/home/guy/devops/AirgapProject"
BARE_REPO="${BASE_DIR}/repos/helm-charts.git"
WORK_DIR=$(mktemp -d)

HARBOR_HOST="harbor.local"
HARBOR_PORT="8080"
HARBOR_REGISTRY="${HARBOR_HOST}:${HARBOR_PORT}"
HARBOR_PROJECT="library"
HARBOR_USER="admin"
HARBOR_PASS="Harbor12345"
HARBOR_URL="http://${HARBOR_REGISTRY}"

NETTOOLS_IMAGE="wbitt/network-multitool"
NETTOOLS_TAG="latest"

echo "============================================"
echo " Step 1: Mirror network-multitool to Harbor"
echo "============================================"

# Ensure port-forward is active
if ! curl -s -o /dev/null --max-time 3 "${HARBOR_URL}/"; then
  echo ">>> Starting port-forward..."
  pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
  sleep 1
  nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
  for i in $(seq 1 15); do
    curl -s -o /dev/null --max-time 2 "${HARBOR_URL}/" && break
    echo "  waiting... (${i}/15)"; sleep 2
  done
fi

echo "${HARBOR_PASS}" | docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" --password-stdin

SOURCE="${NETTOOLS_IMAGE}:${NETTOOLS_TAG}"
TARGET="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/network-multitool:${NETTOOLS_TAG}"

echo ">>> Pulling ${SOURCE}..."
docker pull "${SOURCE}"
echo ">>> Tagging -> ${TARGET}"
docker tag "${SOURCE}" "${TARGET}"
echo ">>> Pushing to Harbor..."
docker push "${TARGET}"
echo ">>> Image mirrored: ${TARGET}"

echo ""
echo "============================================"
echo " Step 2: Create bare Git repository"
echo "============================================"

mkdir -p "$(dirname "${BARE_REPO}")"
if [[ -d "${BARE_REPO}" ]]; then
  echo ">>> Bare repo already exists at ${BARE_REPO}, removing and recreating..."
  rm -rf "${BARE_REPO}"
fi

git init --bare "${BARE_REPO}"
# Set default branch to main
git --git-dir="${BARE_REPO}" symbolic-ref HEAD refs/heads/main
echo ">>> Bare repo created: ${BARE_REPO}"

echo ""
echo "============================================"
echo " Step 3: Create Helm chart"
echo "============================================"

CHART_DIR="${WORK_DIR}/helm-charts/networktools"
mkdir -p "${CHART_DIR}/templates"

# --- Chart.yaml ---
cat > "${CHART_DIR}/Chart.yaml" << 'EOF'
apiVersion: v2
name: networktools
description: A network multitool application for testing and troubleshooting
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

# --- values.yaml ---
cat > "${CHART_DIR}/values.yaml" << EOF
replicaCount: 1

image:
  repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/network-multitool
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

# --- templates/deployment.yaml ---
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

# --- templates/service.yaml ---
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

# --- templates/configmap.yaml ---
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

echo ">>> Helm chart created at ${CHART_DIR}"

echo ""
echo "============================================"
echo " Step 4: Validate Helm chart"
echo "============================================"

helm lint "${CHART_DIR}"
echo ""
helm template test "${CHART_DIR}" --debug 2>&1 | head -20
echo "  ... (template renders successfully)"

echo ""
echo "============================================"
echo " Step 5: Push chart to bare Git repository"
echo "============================================"

cd "${WORK_DIR}/helm-charts"
git init
git checkout -b main
git add .
git commit -m "Initial commit: networktools Helm chart

- Deploys wbitt/network-multitool from Harbor registry
- Configurable replicas, custom welcome page
- Includes Deployment, Service, and ConfigMap templates"

git remote add origin "${BARE_REPO}"
git push origin main

echo ""
echo ">>> Chart pushed to bare repo: ${BARE_REPO}"

echo ""
echo "============================================"
echo " Step 6: Verify repository contents"
echo "============================================"

echo "--- Branches ---"
git --git-dir="${BARE_REPO}" branch

echo ""
echo "--- Files in repo ---"
git --git-dir="${BARE_REPO}" ls-tree -r --name-only HEAD

echo ""
echo "--- Latest commit ---"
git --git-dir="${BARE_REPO}" log --oneline -1

# Cleanup
rm -rf "${WORK_DIR}"

echo ""
echo "============================================"
echo " Done!"
echo "============================================"
echo ""
echo "Bare Git repo:  ${BARE_REPO}"
echo "Chart path:     networktools/"
echo "Image:          ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/network-multitool:${NETTOOLS_TAG}"
echo ""
echo "ArgoCD can use this repo with:"
echo "  repoURL: ${BARE_REPO}"
echo "  path:    networktools"
echo "  targetRevision: main"
