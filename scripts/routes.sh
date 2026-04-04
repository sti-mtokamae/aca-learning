#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found: $ENV_FILE"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
GATEWAY_APP="${GATEWAY_APP:-apisix-gateway}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-}"

if [[ -z "$RESOURCE_GROUP" || -z "$APISIX_ADMIN_KEY" ]]; then
  echo "ERROR: RESOURCE_GROUP and APISIX_ADMIN_KEY are required"
  exit 1
fi

echo "Listing APISIX routes from $GATEWAY_APP ..."
delays=(2 5 10)
max_attempts=4
attempt=1
RAW=""
last_rc=0

while [[ "$attempt" -le "$max_attempts" ]]; do
  set +e
  RAW=$(az containerapp exec \
    --name "$GATEWAY_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --container route-loader \
    --command "curl -sS -H X-API-KEY:$APISIX_ADMIN_KEY http://127.0.0.1:9180/apisix/admin/routes" 2>&1)
  last_rc=$?
  set -e

  if [[ "$last_rc" -eq 0 ]] && ! printf '%s' "$RAW" | grep -q 'ClusterExecFailure'; then
    break
  fi

  if ! printf '%s' "$RAW" | grep -q 'ClusterExecFailure'; then
    echo "ERROR: az containerapp exec failed with a non-retryable error."
    echo "$RAW"
    exit 1
  fi

  if [[ "$attempt" -eq "$max_attempts" ]]; then
    echo "WARN: az containerapp exec failed after retries (ClusterExecFailure)."
    echo "Falling back to route-loader logs for management-plane status..."
    LOGS=$(az containerapp logs show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$GATEWAY_APP" \
      --container route-loader \
      --tail 200 2>&1 || true)

    if printf '%s' "$LOGS" | grep -q 'route-loader: done' &&
       printf '%s' "$LOGS" | grep -q 'route-loader: registered hello-root'; then
      echo "route-loader log status: registration completed in current revision"
      echo "(exec is currently rate-limited; route list dump is skipped)"
      exit 0
    fi

    echo "ERROR: could not verify route status via exec or route-loader logs"
    echo "Last exec output:"
    echo "$RAW"
    echo "Recent route-loader logs:"
    echo "$LOGS" | tail -n 80
    exit 1
  fi

  delay="${delays[$((attempt - 1))]}"
  echo "WARN: exec attempt $attempt failed with ClusterExecFailure. Retrying in ${delay}s..."
  sleep "$delay"
  attempt=$((attempt + 1))
done

# az containerapp exec may print headers/noise; extract only the first JSON object.
JSON=$(printf '%s\n' "$RAW" | awk '
  /^{/ && started == 0 { started = 1 }
  started == 1 {
    print
    opens += gsub(/\{/, "{")
    closes += gsub(/\}/, "}")
    if (opens > 0 && opens == closes) {
      exit
    }
  }
')

if [[ -z "$JSON" ]]; then
  echo "WARN: no JSON payload found in exec response."
  echo "Falling back to route-loader logs for management-plane status..."
  LOGS=$(az containerapp logs show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$GATEWAY_APP" \
    --container route-loader \
    --tail 200 2>&1 || true)

  if printf '%s' "$LOGS" | grep -q 'route-loader: done' &&
     printf '%s' "$LOGS" | grep -q 'route-loader: registered hello-root'; then
    echo "route-loader log status: registration completed in current revision"
    echo "(exec output was non-JSON; route list dump is skipped)"
    exit 0
  fi

  echo "ERROR: route status verification failed"
  echo "Last exec output:"
  echo "$RAW"
  echo "Recent route-loader logs:"
  echo "$LOGS" | tail -n 80
  exit 1
fi

echo "$JSON" | jq '{total: (.list | length), routes: [.list[] | {id: .value.id, uri: .value.uri, methods: .value.methods}]}'
