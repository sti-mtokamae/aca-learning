#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found: $ENV_FILE"
  echo "Create it from .env.example first."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
GATEWAY_APP="${GATEWAY_APP:-apisix-gateway}"

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "ERROR: RESOURCE_GROUP is required in .env"
  exit 1
fi

echo "Resolving gateway FQDN..."
GATEWAY_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$GATEWAY_APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

if [[ -z "$GATEWAY_FQDN" ]]; then
  echo "ERROR: could not resolve gateway FQDN"
  exit 1
fi

echo "Gateway: https://$GATEWAY_FQDN"

echo "Running gateway JWT smoke test..."
GATEWAY_URL="https://$GATEWAY_FQDN" "$REPO_ROOT/apisix/verify-jwt-via-gateway.sh"

echo "Smoke test finished."
