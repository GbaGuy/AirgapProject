#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  AirgapProject - Credentials"
echo "============================================"
echo ""

# ---- ArgoCD ----
echo "  ArgoCD (http://argocd.local:8080)"
echo "  ────────────────────────────────"
echo "  Username: admin"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || true
if [ -n "${ARGOCD_PASS:-}" ]; then
  echo "  Password: $ARGOCD_PASS"
else
  echo "  Password: (initial admin secret not found — it may have been deleted)"
fi

echo ""

# ---- Harbor ----
echo "  Harbor (http://harbor.local:8080)"
echo "  ────────────────────────────────"
echo "  Username: admin"
HARBOR_PASS=$(kubectl -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null) || true
if [ -n "${HARBOR_PASS:-}" ]; then
  echo "  Password: $HARBOR_PASS"
else
  echo "  Password: Harbor12345 (default)"
fi

echo ""
echo "============================================"
