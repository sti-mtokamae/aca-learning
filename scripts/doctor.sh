#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

fail=0

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[OK] command: $cmd"
  else
    echo "[NG] command not found: $cmd"
    fail=1
  fi
}

echo "== Command Check =="
check_cmd az
check_cmd jq
check_cmd mvn
check_cmd docker

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[NG] .env not found: $ENV_FILE"
  echo "     run: cp .env.example .env"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo ""
echo "== .env Required Keys =="
required_vars=(
  RESOURCE_GROUP
  ACA_ENV_NAME
  ACR_NAME
  APP_NAME
  APP_SECURITY_USERNAME
  APP_SECURITY_PASSWORD
  APP_JWT_SECRET
  GATEWAY_APP
  HELLO_APP
  APISIX_ADMIN_KEY
)

for v in "${required_vars[@]}"; do
  val="${!v:-}"
  if [[ -z "$val" || "$val" == REPLACE_ME* ]]; then
    echo "[NG] $v is empty or placeholder"
    fail=1
  else
    echo "[OK] $v"
  fi
done

echo ""
echo "== Azure Resource Reachability =="
if az containerapp show -g "$RESOURCE_GROUP" -n "$HELLO_APP" --query name -o tsv >/dev/null 2>&1; then
  echo "[OK] hello app: $HELLO_APP"
else
  echo "[NG] hello app not found: $HELLO_APP"
  fail=1
fi

if az containerapp show -g "$RESOURCE_GROUP" -n "$GATEWAY_APP" --query name -o tsv >/dev/null 2>&1; then
  echo "[OK] gateway app: $GATEWAY_APP"
else
  echo "[NG] gateway app not found: $GATEWAY_APP"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo ""
  echo "Doctor check passed."
else
  echo ""
  echo "Doctor check failed. Fix the [NG] items first."
  exit 1
fi
