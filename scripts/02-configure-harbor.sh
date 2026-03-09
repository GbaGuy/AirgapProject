#!/usr/bin/env bash
set -euo pipefail

#============================================================================
# 02 - Configure Harbor with Ingress (harbor.local:8080)
#
# Verifies Harbor is accessible, creates projects for the airgap deployment,
# and configures Docker to trust the insecure (HTTP) registry.
#============================================================================

HARBOR_HOST="harbor.local"
HARBOR_PORT="8080"
HARBOR_URL="http://${HARBOR_HOST}:${HARBOR_PORT}"
HARBOR_API="${HARBOR_URL}/api/v2.0"
HARBOR_USER="admin"
HARBOR_PASS="Harbor12345"

echo "============================================"
echo " Step 1: Verify Harbor is reachable"
echo "============================================"

# Ensure port-forward is running
if ! curl -s -o /dev/null -w '' --max-time 3 "${HARBOR_URL}" 2>/dev/null; then
  echo ">>> Port-forward not active. Starting it..."
  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &
  sleep 3
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HARBOR_API}/health")
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: Harbor health endpoint returned HTTP ${HTTP_CODE}"
  exit 1
fi

echo ">>> Harbor health check: OK (HTTP 200)"

HEALTH=$(curl -s "${HARBOR_API}/health")
echo "${HEALTH}" | python3 -m json.tool
echo ""

echo "============================================"
echo " Step 2: Create Harbor projects"
echo "============================================"

create_project() {
  local project_name="$1"
  local public="${2:-true}"

  # Check if project already exists
  EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "${HARBOR_API}/projects?name=${project_name}")

  BODY=$(curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "${HARBOR_API}/projects?name=${project_name}")

  # Check if the project name matches exactly in the response
  EXACT_MATCH=$(echo "${BODY}" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
print('true' if any(p['name'] == '${project_name}' for p in projects) else 'false')
" 2>/dev/null || echo "false")

  if [[ "${EXACT_MATCH}" == "true" ]]; then
    echo ">>> Project '${project_name}' already exists - skipping"
    return 0
  fi

  RESP=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${HARBOR_USER}:${HARBOR_PASS}" \
    -X POST "${HARBOR_API}/projects" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"${project_name}\", \"public\": ${public}}")

  if [[ "${RESP}" == "201" ]]; then
    echo ">>> Project '${project_name}' created successfully"
  elif [[ "${RESP}" == "409" ]]; then
    echo ">>> Project '${project_name}' already exists"
  else
    echo "ERROR: Failed to create project '${project_name}' (HTTP ${RESP})"
    return 1
  fi
}

create_project "library" true
create_project "argocd" true

echo ""
echo "--- Current Harbor Projects ---"
curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" "${HARBOR_API}/projects" | \
  python3 -c "
import sys, json
projects = json.load(sys.stdin)
print(f\"{'NAME':<20} {'PUBLIC':<10} {'REPOS':<10}\")
print('-' * 40)
for p in projects:
    public = p.get('metadata', {}).get('public', 'false')
    print(f\"{p['name']:<20} {public:<10} {p['repo_count']:<10}\")
"

echo ""
echo "============================================"
echo " Step 3: Configure Docker insecure registry"
echo "============================================"

DAEMON_JSON="/etc/docker/daemon.json"
INSECURE_ENTRY="${HARBOR_HOST}:${HARBOR_PORT}"

if [[ -f "${DAEMON_JSON}" ]]; then
  # Check if already configured
  if python3 -c "
import json
with open('${DAEMON_JSON}') as f:
    cfg = json.load(f)
registries = cfg.get('insecure-registries', [])
exit(0 if '${INSECURE_ENTRY}' in registries else 1)
" 2>/dev/null; then
    echo ">>> Docker already configured for insecure registry '${INSECURE_ENTRY}'"
  else
    echo ">>> Adding '${INSECURE_ENTRY}' to existing ${DAEMON_JSON}"
    python3 -c "
import json
with open('${DAEMON_JSON}') as f:
    cfg = json.load(f)
registries = cfg.get('insecure-registries', [])
if '${INSECURE_ENTRY}' not in registries:
    registries.append('${INSECURE_ENTRY}')
cfg['insecure-registries'] = registries
with open('${DAEMON_JSON}', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Updated ' + '${DAEMON_JSON}')
" && sudo systemctl restart docker
    echo ">>> Docker daemon restarted"
  fi
else
  echo ">>> Creating ${DAEMON_JSON} with insecure registry '${INSECURE_ENTRY}'"
  echo "{\"insecure-registries\": [\"${INSECURE_ENTRY}\"]}" | python3 -m json.tool | sudo tee "${DAEMON_JSON}" > /dev/null
  sudo systemctl restart docker
  echo ">>> Docker daemon restarted"
fi

echo ""
echo "--- Docker daemon.json ---"
cat "${DAEMON_JSON}"

echo ""
echo "============================================"
echo " Step 4: Test Docker login to Harbor"
echo "============================================"

# Docker restart kills port-forward; restart it and wait for readiness
echo ">>> Ensuring port-forward is active..."
pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
sleep 1
nohup kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${HARBOR_PORT}:80" --address 0.0.0.0 &>/dev/null &

for i in $(seq 1 15); do
  if curl -s -o /dev/null --max-time 2 "${HARBOR_URL}/"; then
    break
  fi
  echo "  waiting for Harbor... (${i}/15)"
  sleep 2
done

echo "${HARBOR_PASS}" | docker login "${INSECURE_ENTRY}" -u "${HARBOR_USER}" --password-stdin
echo ""
echo ">>> Docker login successful!"

echo ""
echo "============================================"
echo " Configuration Complete!"
echo "============================================"
echo ""
echo "Harbor URL:       ${HARBOR_URL}"
echo "Harbor Admin:     ${HARBOR_USER} / ${HARBOR_PASS}"
echo "Projects:         library, argocd"
echo "Docker registry:  ${INSECURE_ENTRY} (insecure/HTTP)"
echo ""
echo "Example push:"
echo "  docker tag myimage:latest ${INSECURE_ENTRY}/argocd/myimage:latest"
echo "  docker push ${INSECURE_ENTRY}/argocd/myimage:latest"
