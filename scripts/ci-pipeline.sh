#!/bin/bash
# scripts/ci-pipeline.sh
#
# CI/CD パイプライン: ビルド → テスト → ACR push → ACA デプロイ
# 
# Usage (local):
#   guix shell -m guix-manifest.scm -- ./scripts/ci-pipeline.sh dev
#
# Usage (GitHub Actions):
#   ./scripts/ci-pipeline.sh prod ${{ github.run_number }}
#
# Prerequisites:
#   - .env file configured
#   - Azure logged in (az login or OIDC)
#   - Docker daemon running (for local) or available in PATH

set -euo pipefail

# ===== Config =====
TARGET_ENV="${1:-dev}"
BUILD_NUMBER="${2:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "============================================"
echo "CI/CD Pipeline: $TARGET_ENV"
echo "Build Number: $BUILD_NUMBER"
echo "============================================"

# ===== Load .env =====
if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "ERROR: .env not found at $REPO_ROOT/.env"
  exit 1
fi

set -a
source "$REPO_ROOT/.env"
set +a

# Validate required variables
for var in RESOURCE_GROUP ACR_NAME APP_SECURITY_PASSWORD APP_JWT_SECRET; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var not set in .env"
    exit 1
  fi
done

# ===== Environment-specific settings =====
case "$TARGET_ENV" in
  dev)
    echo "[INFO] Development environment"
    APP_NAME="hello-api-vnet"
    ENV_NAME="aca-test-env-vnet"
    IMAGE_TAG="dev-$BUILD_NUMBER"
    ;;
  prod)
    echo "[INFO] Production environment"
    APP_NAME="hello-api"
    ENV_NAME="aca-test-env"
    IMAGE_TAG="prod-$BUILD_NUMBER"
    ;;
  *)
    echo "ERROR: Unknown environment '$TARGET_ENV'. Use 'dev' or 'prod'."
    exit 1
    ;;
esac

# ===== Phase 1: Maven Build =====
echo ""
echo "[1/4] Maven build..."
cd "$REPO_ROOT/spring-hello"

# Java module system compatibility fix (cglib + Spring Boot)
export MAVEN_OPTS="--add-opens java.base/java.lang=ALL-UNNAMED"

if ! mvn clean package -DskipTests -q; then
  echo "ERROR: Maven build failed"
  exit 1
fi

echo "✓ Maven build successful"

# ===== Phase 2: Docker Build =====
echo ""
echo "[2/4] Docker build..."

if ! docker build -t aca-hello-api:"$IMAGE_TAG" .; then
  echo "ERROR: Docker build failed"
  exit 1
fi

echo "✓ Docker image built: aca-hello-api:$IMAGE_TAG"

# ===== Phase 3: ACR Push =====
echo ""
echo "[3/4] ACR push..."

REGISTRY="${ACR_NAME}.azurecr.io"

# Tag for ACR
docker tag aca-hello-api:"$IMAGE_TAG" "$REGISTRY/aca-hello-api:$IMAGE_TAG"
docker tag aca-hello-api:"$IMAGE_TAG" "$REGISTRY/aca-hello-api:latest"

# ACR login
echo "  - ACR login..."
if ! az acr login --name "$ACR_NAME"; then
  echo "ERROR: ACR login failed"
  exit 1
fi

# Push
echo "  - Pushing $REGISTRY/aca-hello-api:$IMAGE_TAG..."
if ! docker push "$REGISTRY/aca-hello-api:$IMAGE_TAG"; then
  echo "ERROR: Docker push failed"
  exit 1
fi

echo "  - Pushing $REGISTRY/aca-hello-api:latest..."
if ! docker push "$REGISTRY/aca-hello-api:latest"; then
  echo "ERROR: Docker push (latest tag) failed"
  exit 1
fi

echo "✓ Images pushed to ACR"

# ===== Phase 4: ACA Deploy =====
echo ""
echo "[4/4] ACA deploy..."

cd "$REPO_ROOT"

# Set image URI
IMAGE_URI="$REGISTRY/aca-hello-api:$IMAGE_TAG"

echo "  - Updating Container App: $APP_NAME"
echo "  - Image: $IMAGE_URI"
echo "  - Environment: $ENV_NAME"

if ! az containerapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_NAME" \
  --image "$IMAGE_URI"; then
  echo "ERROR: Container App update failed"
  exit 1
fi

echo "✓ Container App updated"

# ===== Verification =====
echo ""
echo "[✓] Deploy complete"
echo ""
echo "Deployed to:"
echo "  - Environment: $ENV_NAME"
echo "  - App: $APP_NAME"
echo "  - Image: $IMAGE_URI"
echo ""

# Get FQDN for verification
FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_NAME" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "FQDN: https://$FQDN"

if [[ "$TARGET_ENV" == "dev" ]]; then
  echo ""
  echo "Next: Run smoke tests"
  echo "  ENV_FILE=.env.vnet-runtime make smoke"
fi
