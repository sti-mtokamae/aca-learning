#!/bin/bash

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-aca-test-env}"
ACA_ENV_NAME="${ACA_ENV_NAME:-aca-test-env}"
GATEWAY_APP="${GATEWAY_APP:-apisix-gateway}"
HELLO_APP="${HELLO_APP:-hello-api}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
TEMPLATE_PATH="$SCRIPT_DIR/containerapp.yaml"
RESOLVED_PATH="/tmp/apisix-containerapp.resolved.yaml"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-}"

if [[ -z "$APISIX_ADMIN_KEY" ]]; then
  echo "ERROR: APISIX_ADMIN_KEY is required."
  echo "Set it in .env or export APISIX_ADMIN_KEY before running this script."
  exit 1
fi

if [[ "$GATEWAY_APP" != "apisix-gateway" ]]; then
  echo "ERROR: Current template expects GATEWAY_APP=apisix-gateway"
  echo "(containerapp.yaml has a fixed name field)."
  exit 1
fi

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "ERROR: template not found: $TEMPLATE_PATH"
  exit 1
fi

echo "1) Resolve backend API host (internal/external fqdn)"
HELLO_API_FQDN=$(az containerapp show \
  --name "$HELLO_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)

if [[ -z "$HELLO_API_FQDN" ]]; then
  echo "ERROR: Failed to resolve HELLO_API_FQDN from $HELLO_APP"
  exit 1
fi

echo "2) Resolve ACA environment resource ID"
MANAGED_ENV_ID=$(az containerapp env show \
  --name "$ACA_ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

if [[ -z "$MANAGED_ENV_ID" ]]; then
  echo "ERROR: Failed to resolve managed environment ID for $ACA_ENV_NAME"
  exit 1
fi

echo "3) Render deployment YAML from template"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\\\&/g'
}

APISIX_ADMIN_KEY_ESCAPED="$(escape_sed_replacement "$APISIX_ADMIN_KEY")"

sed \
  -e "s|__MANAGED_ENVIRONMENT_ID__|$MANAGED_ENV_ID|g" \
  -e "s|__HELLO_API_HOST__|$HELLO_API_FQDN|g" \
  -e "s|__APISIX_ADMIN_KEY__|$APISIX_ADMIN_KEY_ESCAPED|g" \
  "$TEMPLATE_PATH" > "$RESOLVED_PATH"

echo "4) Deploy/update APISIX gateway (co-located etcd + apisix)"
if az containerapp show --name "$GATEWAY_APP" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp update \
    --name "$GATEWAY_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --yaml "$RESOLVED_PATH" >/dev/null
else
  az containerapp create \
    --resource-group "$RESOURCE_GROUP" \
    --yaml "$RESOLVED_PATH" >/dev/null
fi

echo "5) Ensure gateway ingress is on port 9080"
az containerapp ingress enable \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --type external \
  --target-port 9080 \
  --allow-insecure true >/dev/null

echo "6) Get gateway URL"
GATEWAY_URL=$(az containerapp show \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)

LATEST_REV=$(az containerapp show \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.latestRevisionName -o tsv)

echo ""
echo "APISIX Gateway deployed"
echo "Revision: $LATEST_REV"
echo "Gateway URL: https://$GATEWAY_URL"
echo "Upstream hello-api host: $HELLO_API_FQDN"
echo "Template: $TEMPLATE_PATH"
echo "Next: run ./register-routes.sh to apply routes"