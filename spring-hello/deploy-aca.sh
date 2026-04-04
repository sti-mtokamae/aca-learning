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

# Required inputs (override via env)
ACR_NAME="${ACR_NAME:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-aca-learning-rg}"
ACA_ENV_NAME="${ACA_ENV_NAME:-aca-learning-env}"
APP_NAME="${APP_NAME:-hello-api}"
IMAGE_NAME="${IMAGE_NAME:-aca-hello-api}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
APP_SECURITY_USERNAME="${APP_SECURITY_USERNAME:-acauser}"
APP_SECURITY_PASSWORD="${APP_SECURITY_PASSWORD:-}"
APP_JWT_SECRET="${APP_JWT_SECRET:-}"
APP_JWT_EXPIRATION="${APP_JWT_EXPIRATION:-3600000}"

if [[ -z "$ACR_NAME" ]]; then
  echo "ERROR: ACR_NAME is required."
  echo "Example: ACR_NAME=myregistry ./deploy-aca.sh"
  exit 1
fi

if [[ -z "$APP_JWT_SECRET" ]]; then
  echo "ERROR: APP_JWT_SECRET is required (minimum 32 chars)."
  echo "Example: APP_JWT_SECRET='replace-with-32-plus-char-secret' ACR_NAME=myregistry ./deploy-aca.sh"
  exit 1
fi

if [[ -z "$APP_SECURITY_PASSWORD" ]]; then
  echo "ERROR: APP_SECURITY_PASSWORD is required."
  echo "Set it in .env or export APP_SECURITY_PASSWORD before running this script."
  exit 1
fi

if [[ ${#APP_JWT_SECRET} -lt 32 ]]; then
  echo "ERROR: APP_JWT_SECRET must be at least 32 chars."
  exit 1
fi

IMAGE_REF="${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"

echo "1) Build jar and container image"
mvn -q clean package -DskipTests
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo "2) Push to ACR"
az acr login --name "$ACR_NAME"
docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "$IMAGE_REF"
docker push "$IMAGE_REF"

echo "3) Create or update Container App"
if az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp update \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$IMAGE_REF" \
    --set-env-vars \
      APP_SECURITY_USERNAME="$APP_SECURITY_USERNAME" \
      APP_SECURITY_PASSWORD="$APP_SECURITY_PASSWORD" \
      APP_JWT_SECRET="$APP_JWT_SECRET" \
      APP_JWT_EXPIRATION="$APP_JWT_EXPIRATION"
else
  az containerapp create \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --environment "$ACA_ENV_NAME" \
    --image "$IMAGE_REF" \
    --target-port 8080 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 3 \
    --cpu 0.5 \
    --memory 1Gi \
    --env-vars \
      APP_SECURITY_USERNAME="$APP_SECURITY_USERNAME" \
      APP_SECURITY_PASSWORD="$APP_SECURITY_PASSWORD" \
      APP_JWT_SECRET="$APP_JWT_SECRET" \
      APP_JWT_EXPIRATION="$APP_JWT_EXPIRATION"
fi

FQDN=$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)

echo "Done"
echo "App URL: https://${FQDN}"
echo "Next: APP_URL=https://${FQDN} APP_SECURITY_USERNAME=${APP_SECURITY_USERNAME} APP_SECURITY_PASSWORD=${APP_SECURITY_PASSWORD} ./verify-jwt-aca.sh"
