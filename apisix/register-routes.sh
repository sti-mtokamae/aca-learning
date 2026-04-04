#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Configuration
RESOURCE_GROUP=${RESOURCE_GROUP:-"aca-test-env"}
GATEWAY_APP="apisix-gateway"
API_KEY="${APISIX_ADMIN_KEY:-${API_KEY:-}}"

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: APISIX_ADMIN_KEY (or API_KEY) is required."
  echo "Set it in .env or export APISIX_ADMIN_KEY before running this script."
  exit 1
fi

echo "=== Registering APISIX routes via Admin API ==="

# Get hello-api FQDN
HELLO_API_FQDN=$(az containerapp show -g "$RESOURCE_GROUP" -n "hello-api" --query "properties.configuration.ingress.fqdn" -o tsv)
echo "Hello API FQDN: $HELLO_API_FQDN"

# Get gateway FQDN  
GATEWAY_FQDN=$(az containerapp show -g "$RESOURCE_GROUP" -n "$GATEWAY_APP" --query "properties.configuration.ingress.fqdn" -o tsv)
echo "Gateway FQDN: $GATEWAY_FQDN"

# Note: Admin API is on port 9180 but not exposed externally
# We need to access it via container exec or port-forward

echo "=== Attempting to register routes via container exec ==="

# Register routes using shell commands inside the container
# Format: az containerapp exec -g RG -n APP --command "/bin/sh -c 'command'"

# Register /hello route
echo -n "Registering /hello... "
az containerapp exec \
  -g "$RESOURCE_GROUP" \
  -n "$GATEWAY_APP" \
  --container route-loader \
  --command "/bin/sh -c 'curl -fsS -o /dev/null -X PUT http://localhost:9180/apisix/admin/routes/hello-root -H \"X-API-Key: ${API_KEY}\" -H \"Content-Type: application/json\" -d \"{\\\"uri\\\": \\\"/hello\\\", \\\"methods\\\": [\\\"GET\\\"], \\\"upstream\\\": {\\\"type\\\": \\\"roundrobin\\\", \\\"scheme\\\": \\\"https\\\", \\\"nodes\\\": {\\\"${HELLO_API_FQDN}:443\\\": 1}}, \\\"plugins\\\": {\\\"proxy-rewrite\\\": {\\\"uri\\\": \\\"/api/hello\\\"}}}\" && echo OK'" \
  2>&1 | grep -E "^(OK|✓)" || echo "WARN: Registration may have failed, but continuing..."

# Register /hello/* route
echo -n "Registering /hello/*... "
az containerapp exec \
  -g "$RESOURCE_GROUP" \
  -n "$GATEWAY_APP" \
  --container route-loader \
  --command "/bin/sh -c 'curl -fsS -o /dev/null -X PUT http://localhost:9180/apisix/admin/routes/hello-wildcard -H \"X-API-Key: ${API_KEY}\" -H \"Content-Type: application/json\" -d \"{\\\"uri\\\": \\\"/hello/*\\\", \\\"methods\\\": [\\\"GET\\\"], \\\"upstream\\\": {\\\"type\\\": \\\"roundrobin\\\", \\\"scheme\\\": \\\"https\\\", \\\"nodes\\\": {\\\"${HELLO_API_FQDN}:443\\\": 1}}, \\\"plugins\\\": {\\\"proxy-rewrite\\\": {\\\"regex_uri\\\": [\\\"^/hello/(.*)\\\", \\\"/api/\\\$1\\\"]}}}\" && echo OK'" \
  2>&1 | grep -E "^(OK|✓)" || echo "WARN"

# Register /status route
echo -n "Registering /status... "
az containerapp exec \
  -g "$RESOURCE_GROUP" \
  -n "$GATEWAY_APP" \
  --container route-loader \
  --command "/bin/sh -c 'curl -fsS -o /dev/null -X PUT http://localhost:9180/apisix/admin/routes/status -H \"X-API-Key: ${API_KEY}\" -H \"Content-Type: application/json\" -d \"{\\\"uri\\\": \\\"/status\\\", \\\"methods\\\": [\\\"GET\\\"], \\\"upstream\\\": {\\\"type\\\": \\\"roundrobin\\\", \\\"scheme\\\": \\\"https\\\", \\\"nodes\\\": {\\\"${HELLO_API_FQDN}:443\\\": 1}}, \\\"plugins\\\": {\\\"proxy-rewrite\\\": {\\\"uri\\\": \\\"/api/status\\\"}}}\" && echo OK'" \
  2>&1 | grep -E "^(OK|✓)" || echo "WARN"

# Register /auth/login route
echo -n "Registering /auth/login... "
az containerapp exec \
  -g "$RESOURCE_GROUP" \
  -n "$GATEWAY_APP" \
  --container route-loader \
  --command "/bin/sh -c 'curl -fsS -o /dev/null -X PUT http://localhost:9180/apisix/admin/routes/auth-login -H \"X-API-Key: ${API_KEY}\" -H \"Content-Type: application/json\" -d \"{\\\"uri\\\": \\\"/auth/login\\\", \\\"methods\\\": [\\\"POST\\\"], \\\"upstream\\\": {\\\"type\\\": \\\"roundrobin\\\", \\\"scheme\\\": \\\"https\\\", \\\"nodes\\\": {\\\"${HELLO_API_FQDN}:443\\\": 1}}, \\\"plugins\\\": {\\\"proxy-rewrite\\\": {\\\"uri\\\": \\\"/api/auth/login\\\"}}}\" && echo OK'" \
  2>&1 | grep -E "^(OK|✓)" || echo "WARN"

echo ""
echo "=== Waiting for routes to propagate (10 seconds) ==="
sleep 10

echo ""
echo "=== Testing gateway routing ==="
echo "Testing /hello:"
curl -sS "https://$GATEWAY_FQDN/hello" | head -c 300
echo ""
echo ""

echo "Testing /status:"
curl -sS "https://$GATEWAY_FQDN/status" | head -c 300
echo ""
echo ""

echo "=== Route deployment complete ==="
