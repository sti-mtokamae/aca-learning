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

APP_URL="${APP_URL:-}"
APP_SECURITY_USERNAME="${APP_SECURITY_USERNAME:-acauser}"
APP_SECURITY_PASSWORD="${APP_SECURITY_PASSWORD:-}"

if [[ -z "$APP_URL" ]]; then
  echo "ERROR: APP_URL is required."
  echo "Example: APP_URL=https://hello-api.<fqdn> ./verify-jwt-aca.sh"
  exit 1
fi

if [[ -z "$APP_SECURITY_PASSWORD" ]]; then
  echo "ERROR: APP_SECURITY_PASSWORD is required."
  echo "Set it in .env or export APP_SECURITY_PASSWORD before running this script."
  exit 1
fi

echo "1) Health endpoint (public)"
curl -fsS "${APP_URL}/actuator/health" | cat
echo

echo "2) Login and token"
LOGIN_JSON=$(curl -fsS -X POST "${APP_URL}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${APP_SECURITY_USERNAME}\",\"password\":\"${APP_SECURITY_PASSWORD}\"}")
TOKEN=$(printf '%s' "$LOGIN_JSON" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: token extraction failed"
  echo "$LOGIN_JSON"
  exit 1
fi

echo "Token acquired: ${#TOKEN} chars"

echo "3) Protected endpoint with Bearer token"
curl -fsS -H "Authorization: Bearer ${TOKEN}" "${APP_URL}/api/hello" | cat
echo

echo "4) Protected endpoint without token should fail"
HTTP_NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}/api/hello")
echo "HTTP without token: ${HTTP_NOAUTH}"
