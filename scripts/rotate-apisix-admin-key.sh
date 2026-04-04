#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found: $ENV_FILE"
  exit 1
fi

timestamp="$(date +%Y%m%d%H%M%S)"
BACKUP_FILE="$ENV_FILE.bak.apisix-key.$timestamp"
cp "$ENV_FILE" "$BACKUP_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

OLD_KEY="${APISIX_ADMIN_KEY:-}"
if [[ -z "$OLD_KEY" ]]; then
  echo "ERROR: APISIX_ADMIN_KEY is missing in .env"
  exit 1
fi

NEW_KEY="${NEW_APISIX_ADMIN_KEY:-$(openssl rand -hex 24)}"
if [[ "$NEW_KEY" == "$OLD_KEY" ]]; then
  echo "ERROR: NEW_APISIX_ADMIN_KEY must be different from current key"
  exit 1
fi

restore_needed=1

rollback() {
  if [[ "$restore_needed" -eq 0 ]]; then
    return
  fi

  echo ""
  echo "Rotation failed. Rolling back .env and APISIX deployment..."
  set +e
  cp "$BACKUP_FILE" "$ENV_FILE"
  cd "$REPO_ROOT/apisix" && ENV_FILE="$ENV_FILE" ./deploy.sh >/tmp/apisix-rollback.log 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    cd "$REPO_ROOT" && ENV_FILE="$ENV_FILE" ./apisix/register-routes.sh >/tmp/apisix-rollback-routes.log 2>&1
    rc=$?
  fi
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "Rollback completed."
  else
    echo "Rollback command failed. Check: /tmp/apisix-rollback.log and /tmp/apisix-rollback-routes.log"
  fi
}

trap rollback ERR

sed -i "s|^APISIX_ADMIN_KEY=.*$|APISIX_ADMIN_KEY=$NEW_KEY|" "$ENV_FILE"

if ! grep -q "^APISIX_ADMIN_KEY=$NEW_KEY$" "$ENV_FILE"; then
  echo "ERROR: failed to update APISIX_ADMIN_KEY in .env"
  exit 1
fi

echo "Applying new APISIX admin key to ACA..."
cd "$REPO_ROOT/apisix"
ENV_FILE="$ENV_FILE" ./deploy.sh >/tmp/apisix-rotate-deploy.log

echo "Applying routes with new key..."
cd "$REPO_ROOT"
ENV_FILE="$ENV_FILE" ./apisix/register-routes.sh >/tmp/apisix-rotate-routes.log

echo "Running smoke test (with warm-up retry)..."
cd "$REPO_ROOT"

smoke_ok=0
for i in 1 2 3 4; do
  set +e
  ENV_FILE="$ENV_FILE" ./scripts/smoke.sh >/tmp/apisix-rotate-smoke.log 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    smoke_ok=1
    break
  fi

  if [[ "$i" -lt 4 ]]; then
    echo "Smoke attempt $i failed, waiting for route-loader warm-up..."
    sleep 5
  fi
done

if [[ "$smoke_ok" -ne 1 ]]; then
  echo "ERROR: smoke test failed after retries"
  cat /tmp/apisix-rotate-smoke.log
  exit 1
fi

restore_needed=0
trap - ERR

echo ""
echo "APISIX admin key rotation completed."
echo "Backup file: $BACKUP_FILE"
echo "New key prefix: ${NEW_KEY:0:8}..."
echo "Logs: /tmp/apisix-rotate-deploy.log, /tmp/apisix-rotate-routes.log, /tmp/apisix-rotate-smoke.log"