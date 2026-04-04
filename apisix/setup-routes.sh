#!/bin/bash

# APISIX Route setup for ACA Learning
# 前提: APISIX Gateway と Hello API がデプロイ済み

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-aca-test-env}"
GATEWAY_APP="${GATEWAY_APP:-apisix-gateway}"
HELLO_APP="${HELLO_APP:-hello-api}"

GATEWAY_URL=$(az containerapp show \
  --name "$GATEWAY_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)

API_URL=$(az containerapp show \
  --name "$HELLO_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)

echo "Configuring APISIX routes..."
echo "Gateway public URL: https://$GATEWAY_URL"
echo "Backend API URL: https://$API_URL"

put_route_via_exec() {
  local route_id="$1"
  local payload_b64="$2"

  az containerapp exec \
    --name "$GATEWAY_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --container etcd \
    --command "sh -lc \"val=\$(echo '$payload_b64' | base64 -d); etcdctl --endpoints=http://127.0.0.1:2379 put /apisix/routes/$route_id \"\$val\"\""
}

echo "1. Creating route for /hello ..."
ROUTE_HELLO_ROOT_B64=$(printf '%s' "{\"name\":\"hello-root-route\",\"uri\":\"/hello\",\"upstream\":{\"type\":\"roundrobin\",\"nodes\":{\"$API_URL:443\":1},\"scheme\":\"https\"},\"plugins\":{\"proxy-rewrite\":{\"uri\":\"/api/hello\"}}}" | base64 -w0)
put_route_via_exec "hello-root" "$ROUTE_HELLO_ROOT_B64"

echo "2. Creating route for /hello/* ..."
ROUTE_HELLO_API_B64=$(printf '%s' "{\"name\":\"hello-api-route\",\"uri\":\"/hello/*\",\"upstream\":{\"type\":\"roundrobin\",\"nodes\":{\"$API_URL:443\":1},\"scheme\":\"https\"},\"plugins\":{\"proxy-rewrite\":{\"regex_uri\":[\"^/hello/(.*)\",\"/api/\$1\"]}}}" | base64 -w0)
put_route_via_exec "hello-api" "$ROUTE_HELLO_API_B64"

echo "3. Creating route for /status ..."
ROUTE_STATUS_B64=$(printf '%s' "{\"name\":\"status-route\",\"uri\":\"/status\",\"upstream\":{\"type\":\"roundrobin\",\"nodes\":{\"$API_URL:443\":1},\"scheme\":\"https\"},\"plugins\":{\"proxy-rewrite\":{\"uri\":\"/api/status\"}}}" | base64 -w0)
put_route_via_exec "status" "$ROUTE_STATUS_B64"

echo "4. Creating route for /auth/login ..."
ROUTE_AUTH_LOGIN_B64=$(printf '%s' "{\"name\":\"auth-login-route\",\"uri\":\"/auth/login\",\"upstream\":{\"type\":\"roundrobin\",\"nodes\":{\"$API_URL:443\":1},\"scheme\":\"https\"},\"plugins\":{\"proxy-rewrite\":{\"uri\":\"/api/auth/login\"}}}" | base64 -w0)
put_route_via_exec "auth-login" "$ROUTE_AUTH_LOGIN_B64"

echo ""
echo "Routes configured"
echo ""
echo "Test commands:"
echo "  curl https://$GATEWAY_URL/hello"
echo "  curl https://$GATEWAY_URL/hello/yourname"
echo "  curl https://$GATEWAY_URL/status"
echo "  curl -X POST https://$GATEWAY_URL/auth/login -H 'Content-Type: application/json' -d '{\"username\":\"$APP_SECURITY_USERNAME\",\"password\":\"$APP_SECURITY_PASSWORD\"}'"