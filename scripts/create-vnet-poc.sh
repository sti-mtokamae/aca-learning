#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
VNET_ENV_FILE="${VNET_ENV_FILE:-$REPO_ROOT/.env.vnet-checklist}"

load_env_file() {
  local file_path="$1"

  if [[ -f "$file_path" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file_path"
    set +a
  fi
}

require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: command not found: $cmd"
    exit 1
  fi
}

is_placeholder() {
  local value="$1"

  [[ -z "$value" || "$value" == REPLACE_ME* || "$value" == "<"*">" ]]
}

require_value() {
  local key="$1"
  local value="$2"

  if is_placeholder "$value"; then
    echo "ERROR: $key is empty or placeholder"
    exit 1
  fi
}

ensure_nsg_rule() {
  local rule_name="$1"
  shift

  if az network nsg rule show \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "$rule_name" >/dev/null 2>&1; then
    echo "[OK] NSG rule exists: $rule_name"
    return
  fi

  echo "[CREATE] NSG rule: $rule_name"
  az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "$rule_name" \
    "$@" \
    >/dev/null
}

require_command az

load_env_file "$ENV_FILE"
load_env_file "$VNET_ENV_FILE"

RESOURCE_GROUP="${RESOURCE_GROUP:-}"
LOCATION="${LOCATION:-}"
VNET_NAME="${VNET_NAME:-}"
SUBNET_NAME="${SUBNET_NAME:-}"
NSG_NAME="${NSG_NAME:-}"
VNET_CIDR="${VNET_CIDR:-}"
SUBNET_CIDR="${SUBNET_CIDR:-}"
SUBNET_DELEGATION="${SUBNET_DELEGATION:-Microsoft.App/environments}"
INTERNET_INGRESS_PORT="${INTERNET_INGRESS_PORT:-9080}"
NEW_ACA_ENV_NAME="${NEW_ACA_ENV_NAME:-}"

require_value RESOURCE_GROUP "$RESOURCE_GROUP"
require_value VNET_NAME "$VNET_NAME"
require_value SUBNET_NAME "$SUBNET_NAME"
require_value NSG_NAME "$NSG_NAME"
require_value VNET_CIDR "$VNET_CIDR"
require_value SUBNET_CIDR "$SUBNET_CIDR"

if is_placeholder "$LOCATION"; then
  LOCATION="$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)"
fi

require_value LOCATION "$LOCATION"

echo "== VNet PoC Settings =="
echo "RESOURCE_GROUP=$RESOURCE_GROUP"
echo "LOCATION=$LOCATION"
echo "VNET_NAME=$VNET_NAME"
echo "SUBNET_NAME=$SUBNET_NAME"
echo "NSG_NAME=$NSG_NAME"
echo "VNET_CIDR=$VNET_CIDR"
echo "SUBNET_CIDR=$SUBNET_CIDR"
echo "SUBNET_DELEGATION=$SUBNET_DELEGATION"
echo ""

if az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" >/dev/null 2>&1; then
  echo "[OK] NSG exists: $NSG_NAME"
else
  echo "[CREATE] NSG: $NSG_NAME"
  az network nsg create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NSG_NAME" \
    --location "$LOCATION" \
    >/dev/null
fi

if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" >/dev/null 2>&1; then
  echo "[OK] VNet exists: $VNET_NAME"
else
  echo "[CREATE] VNet: $VNET_NAME"
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --location "$LOCATION" \
    --address-prefixes "$VNET_CIDR" \
    --subnet-name "$SUBNET_NAME" \
    --subnet-prefixes "$SUBNET_CIDR" \
    --nsg "$NSG_NAME" \
    >/dev/null
fi

if az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" >/dev/null 2>&1; then
  echo "[UPDATE] Subnet association/delegation: $SUBNET_NAME"
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    --delegations "$SUBNET_DELEGATION" \
    >/dev/null
else
  echo "[CREATE] Subnet: $SUBNET_NAME"
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --address-prefixes "$SUBNET_CIDR" \
    --network-security-group "$NSG_NAME" \
    --delegations "$SUBNET_DELEGATION" \
    >/dev/null
fi

ensure_nsg_rule "allow-internet-${INTERNET_INGRESS_PORT}" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes Internet \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges "$INTERNET_INGRESS_PORT" \
  --description "Allow public ingress to APISIX gateway"

ensure_nsg_rule "allow-vnet-https" \
  --priority 110 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes VirtualNetwork \
  --source-port-ranges '*' \
  --destination-address-prefixes VirtualNetwork \
  --destination-port-ranges 443 \
  --description "Allow internal ACA app-to-app HTTPS"

ensure_nsg_rule "allow-storage-443" \
  --priority 120 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes VirtualNetwork \
  --source-port-ranges '*' \
  --destination-address-prefixes Storage \
  --destination-port-ranges 443 \
  --description "Allow outbound access to Azure Storage"

SUBNET_ID="$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --query id -o tsv)"

echo ""
echo "VNet PoC network resources are ready."
echo "Subnet ID: $SUBNET_ID"

if ! is_placeholder "$NEW_ACA_ENV_NAME"; then
  echo "Next suggested command:"
  echo "az containerapp env create --name $NEW_ACA_ENV_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --infrastructure-subnet-resource-id $SUBNET_ID"
fi

echo "Note: deny rules are intentionally not added in this PoC script."
echo "      ACA control-plane requirements should be validated before tightening NSG defaults."