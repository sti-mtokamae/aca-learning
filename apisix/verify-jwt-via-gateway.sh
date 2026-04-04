#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

GATEWAY_URL="${GATEWAY_URL:-}"
APP_SECURITY_USERNAME="${APP_SECURITY_USERNAME:-acauser}"
APP_SECURITY_PASSWORD="${APP_SECURITY_PASSWORD:-}"

if [[ -z "$GATEWAY_URL" ]]; then
  echo "ERROR: GATEWAY_URL is required."
  echo "Example: GATEWAY_URL=https://apisix-gateway.<fqdn> ./verify-jwt-via-gateway.sh"
  exit 1
fi

if [[ -z "$APP_SECURITY_PASSWORD" ]]; then
  echo "ERROR: APP_SECURITY_PASSWORD is required."
  echo "Set it in .env or export APP_SECURITY_PASSWORD before running this script."
  exit 1
fi

echo "1) Login via APISIX"
LOGIN_JSON=$(curl -fsS -X POST "${GATEWAY_URL}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${APP_SECURITY_USERNAME}\",\"password\":\"${APP_SECURITY_PASSWORD}\"}")

TOKEN=$(printf '%s' "$LOGIN_JSON" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: token extraction failed"
  echo "$LOGIN_JSON"
  exit 1
fi

echo "Token acquired via gateway: ${#TOKEN} chars"

echo "2) Protected call via APISIX with Bearer"
curl -fsS -H "Authorization: Bearer ${TOKEN}" "${GATEWAY_URL}/hello" | cat
echo

echo "3) Protected call via APISIX without token should fail"
HTTP_NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/hello")
echo "HTTP without token: ${HTTP_NOAUTH}"
