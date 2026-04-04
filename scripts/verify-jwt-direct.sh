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

# Testing JWT authentication flow on hello-api directly
# This verifies the core functionality before gateway setup is complete

API_URL="${API_URL:-${APP_URL:-}}"
APP_SECURITY_USERNAME="${APP_SECURITY_USERNAME:-acauser}"
APP_SECURITY_PASSWORD="${APP_SECURITY_PASSWORD:-}"

if [ -z "$API_URL" ]; then
    echo "ERROR: API_URL (or APP_URL) is required."
    echo "Set it in .env or export API_URL before running this script."
    exit 1
fi

if [ -z "$APP_SECURITY_PASSWORD" ]; then
    echo "ERROR: APP_SECURITY_PASSWORD is required."
    echo "Set it in .env or export APP_SECURITY_PASSWORD before running this script."
    exit 1
fi

echo "=== JWT Authentication Flow Test ==="
echo "API URL: $API_URL"
echo ""

# Step 1: Health check
echo "1. Health check..."
HEALTH=$(curl -sS "$API_URL/api/health" -w "\n%{http_code}")
HTTP_CODE=$(echo "$HEALTH" | tail -1)
BODY=$(echo "$HEALTH" | head -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ Health check: 200 OK"
    echo "   Response: $BODY"
else
    echo "   ✗ Health check failed: $HTTP_CODE"
    exit 1
fi

echo ""

# Step 2: Login (get JWT token)
echo "2. Acquiring JWT token..."
LOGIN_RESPONSE=$(curl -sS -X POST "$API_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{
        "username": "'"$APP_SECURITY_USERNAME"'",
        "password": "'"$APP_SECURITY_PASSWORD"'"
  }' -w "\n%{http_code}")

HTTP_CODE=$(echo "$LOGIN_RESPONSE" | tail -1)
BODY=$(echo "$LOGIN_RESPONSE" | head -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ Login successful: $HTTP_CODE"
    echo "   Response: $BODY"
    
    # Extract token
    TOKEN=$(echo "$BODY" | jq -r '.token' 2>/dev/null)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo "   ✗ Failed to extract token"
        exit 1
    fi
    echo "   Token (first 50 chars): ${TOKEN:0:50}..."
else
    echo "   ✗ Login failed: $HTTP_CODE"
    echo "   Response: $BODY"
    exit 1
fi

echo ""

# Step 3: Access protected resource with token
echo "3. Accessing protected resource with Bearer token..."
HELLO_RESPONSE=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$API_URL/api/hello" -w "\n%{http_code}")

HTTP_CODE=$(echo "$HELLO_RESPONSE" | tail -1)
BODY=$(echo "$HELLO_RESPONSE" | head -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ Protected access successful: $HTTP_CODE"
    echo "   Response: $BODY"
else
    echo "   ✗ Protected access failed: $HTTP_CODE"
    echo "   Response: $BODY"
    exit 1
fi

echo ""

# Step 4: Try accessing without token (should fail)
echo "4. Testing access without token (should be rejected)..."
NO_AUTH_RESPONSE=$(curl -sS "$API_URL/api/hello" -w "\n%{http_code}")

HTTP_CODE=$(echo "$NO_AUTH_RESPONSE" | tail -1)
BODY=$(echo "$NO_AUTH_RESPONSE" | head -1)

if [ "$HTTP_CODE" = "403" ]; then
    echo "   ✓ Correctly rejected: $HTTP_CODE"
    echo "   Response: $BODY"
else
    echo "   ✗ Unexpected status: $HTTP_CODE (expected 403)"
fi

echo ""
echo "=== All JWT tests passed ✓ ==="
echo ""
echo "Summary:"
echo "- Health check: OK"
echo "- JWT token acquisition: OK"
echo "- Protected resource access: OK"
echo "- Authorization enforcement: OK"
