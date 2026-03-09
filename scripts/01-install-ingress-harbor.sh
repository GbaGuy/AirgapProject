#!/usr/bin/env bash
set -euo pipefail

#============================================================================
# 01 - Install Nginx Ingress Controller + Harbor Registry
#
# Installs both components from the internet on a Kind cluster.
# Harbor will serve as the local OCI registry for airgap deployments.
# Nginx Ingress Controller exposes Harbor (and later ArgoCD) via hostnames.
#============================================================================

HARBOR_NAMESPACE="harbor"
INGRESS_NAMESPACE="ingress-nginx"
HARBOR_ADMIN_PASSWORD="Harbor12345"
HARBOR_HOSTNAME="harbor.local"

echo "============================================"
echo " Step 1: Add Helm repositories"
echo "============================================"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add harbor https://helm.goharbor.io
helm repo update

echo ""
echo "============================================"
echo " Step 2: Install Nginx Ingress Controller"
echo "============================================"
kubectl create namespace "${INGRESS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "${INGRESS_NAMESPACE}" \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --set controller.admissionWebhooks.enabled=false \
  --wait --timeout 120s

echo ""
echo ">>> Nginx Ingress Controller installed. Waiting for pods..."
kubectl wait --namespace "${INGRESS_NAMESPACE}" \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo ""
echo "============================================"
echo " Step 3: Install Harbor Registry"
echo "============================================"
kubectl create namespace "${HARBOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install harbor harbor/harbor \
  --namespace "${HARBOR_NAMESPACE}" \
  --set expose.type=ingress \
  --set expose.ingress.className=nginx \
  --set expose.ingress.hosts.core="${HARBOR_HOSTNAME}" \
  --set expose.tls.enabled=false \
  --set externalURL="http://${HARBOR_HOSTNAME}" \
  --set harborAdminPassword="${HARBOR_ADMIN_PASSWORD}" \
  --set persistence.enabled=false \
  --wait --timeout 300s

echo ""
echo ">>> Harbor installed. Waiting for all pods to be ready..."
kubectl wait --namespace "${HARBOR_NAMESPACE}" \
  --for=condition=Ready pod --all \
  --timeout=300s

echo ""
echo "============================================"
echo " Step 4: Verify installation"
echo "============================================"
echo ""
echo "--- Ingress Controller Pods ---"
kubectl get pods -n "${INGRESS_NAMESPACE}"
echo ""
echo "--- Harbor Pods ---"
kubectl get pods -n "${HARBOR_NAMESPACE}"
echo ""
echo "--- Ingress Resources ---"
kubectl get ingress -n "${HARBOR_NAMESPACE}"

echo ""
echo "============================================"
echo " Setup Complete!"
echo "============================================"
echo ""
echo "Harbor URL:      http://${HARBOR_HOSTNAME}"
echo "Harbor Admin:    admin / ${HARBOR_ADMIN_PASSWORD}"
echo ""
echo "To access Harbor, add this to /etc/hosts:"
echo "  127.0.0.1  ${HARBOR_HOSTNAME}"
echo ""
echo "Then port-forward the ingress controller:"
echo "  kubectl port-forward -n ${INGRESS_NAMESPACE} svc/ingress-nginx-controller 8080:80 --address 0.0.0.0"
echo ""
echo "Access Harbor at: http://${HARBOR_HOSTNAME}:8080"
