#!/usr/bin/env bash
set -euo pipefail

# Script: add_mysql_networking.sh
# Purpose: Create and approve a Managed Private Endpoint (MPE) for MySQL <-> Grafana connectivity
# Usage: ./add_mysql_networking.sh --grafana-rg <rg> --grafana-name <name> --mysql-rg <rg> \
#          --mysql-server <server> [--mpe-name <name>] [--subscription <id>]

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$THIS_DIR/util.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found in PATH"
    exit 1
fi

GRAFANA_RG=""
GRAFANA_NAME=""
MYSQL_RG=""
MYSQL_SERVER=""
MPE_NAME=""
SUBSCRIPTION_ID=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --grafana-rg)
            require_option_value "$@"
            GRAFANA_RG="$2"
            shift 2
            ;;
        --grafana-name)
            require_option_value "$@"
            GRAFANA_NAME="$2"
            shift 2
            ;;
        --mysql-rg)
            require_option_value "$@"
            MYSQL_RG="$2"
            shift 2
            ;;
        --mysql-server)
            require_option_value "$@"
            MYSQL_SERVER="$2"
            shift 2
            ;;
        --mpe-name)
            require_option_value "$@"
            MPE_NAME="$2"
            shift 2
            ;;
        --subscription)
            require_option_value "$@"
            SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            echo "ERROR: Unexpected argument: $1" >&2
            exit 1
            ;;
    esac
done

GRAFANA_RG=$(strip_carriage_returns "$GRAFANA_RG")
GRAFANA_NAME=$(strip_carriage_returns "$GRAFANA_NAME")
MYSQL_RG=$(strip_carriage_returns "$MYSQL_RG")
MYSQL_SERVER=$(strip_carriage_returns "$MYSQL_SERVER")
MPE_NAME=$(strip_carriage_returns "$MPE_NAME")
SUBSCRIPTION_ID=$(strip_carriage_returns "$SUBSCRIPTION_ID")

# Validate required arguments
MISSING_ARGS=()
[[ -z "$GRAFANA_RG" ]] && MISSING_ARGS+=("--grafana-rg")
[[ -z "$GRAFANA_NAME" ]] && MISSING_ARGS+=("--grafana-name")
[[ -z "$MYSQL_RG" ]] && MISSING_ARGS+=("--mysql-rg")
[[ -z "$MYSQL_SERVER" ]] && MISSING_ARGS+=("--mysql-server")

if [ ${#MISSING_ARGS[@]} -gt 0 ]; then
    echo "ERROR: Missing required arguments: ${MISSING_ARGS[*]}"
    echo ""
    echo "Usage: $0 \\"
    echo "  --grafana-rg <resource-group> \\"
    echo "  --grafana-name <workspace-name> \\"
    echo "  --mysql-rg <resource-group> \\"
    echo "  --mysql-server <server-name> \\"
    echo "  [--mpe-name <endpoint-name>] \\"
    echo "  [--subscription <subscription-id>]"
    echo ""
    echo "If --mpe-name is not provided, it defaults to '<mysql-server>-mpe'"
    exit 1
fi

# Generate default MPE name if not provided
if [[ -z "$MPE_NAME" ]]; then
    MPE_NAME="${MYSQL_SERVER}-mpe"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MySQL Private Endpoint Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Grafana: $GRAFANA_NAME (rg: $GRAFANA_RG)"
echo "MySQL:   $MYSQL_SERVER (rg: $MYSQL_RG)"
echo "MPE:     $MPE_NAME"
echo ""

# Verify Grafana workspace exists
echo "[1/6] Verifying Grafana workspace exists..."
GRAFANA_LOOKUP_ARGS=(
    --name "$GRAFANA_NAME"
    --resource-group "$GRAFANA_RG"
)
if [[ -n "$SUBSCRIPTION_ID" ]]; then
    GRAFANA_LOOKUP_ARGS+=(--subscription "$SUBSCRIPTION_ID")
fi
if ! GRAFANA_DETAILS=$(az grafana show \
    "${GRAFANA_LOOKUP_ARGS[@]}" \
    -o json 2>/dev/null); then
    echo "ERROR: Grafana workspace '$GRAFANA_NAME' not found in resource group '$GRAFANA_RG'"
    exit 1
fi
GRAFANA_REGION=$(echo "$GRAFANA_DETAILS" | jq -r '.location // empty' | strip_carriage_returns)
GRAFANA_SUBSCRIPTION_ID=$(echo "$GRAFANA_DETAILS" | jq -r '.id // empty' | cut -d/ -f3 | strip_carriage_returns)
if [[ -z "$GRAFANA_REGION" || -z "$GRAFANA_SUBSCRIPTION_ID" ]]; then
    echo "ERROR: Could not determine Grafana workspace location or subscription"
    exit 1
fi
if [[ -z "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID="$GRAFANA_SUBSCRIPTION_ID"
fi
echo "✓ Grafana workspace found"

# Verify MySQL server exists
echo "[2/6] Verifying MySQL server exists..."
if ! MYSQL_ID=$(az mysql flexible-server show \
    --resource-group "$MYSQL_RG" \
    --name "$MYSQL_SERVER" \
    --query id \
    -o tsv 2>/dev/null | strip_carriage_returns); then
    echo "ERROR: MySQL server '$MYSQL_SERVER' not found in resource group '$MYSQL_RG'"
    exit 1
fi
MYSQL_SUBSCRIPTION_ID=$(echo "$MYSQL_ID" | cut -d/ -f3 | strip_carriage_returns)
echo "✓ MySQL server found: $MYSQL_ID"

# Get MySQL region
echo "[3/6] Getting MySQL server region..."
MYSQL_REGION=$(az mysql flexible-server show \
    --resource-group "$MYSQL_RG" \
    --name "$MYSQL_SERVER" \
    --query location \
    -o tsv | strip_carriage_returns)
echo "✓ MySQL region: $MYSQL_REGION"

# Check if MPE already exists
echo "[4/6] Checking if Managed Private Endpoint already exists..."
EXISTING_MPE=$(az grafana managed-private-endpoint show \
    --resource-group "$GRAFANA_RG" \
    --subscription "$SUBSCRIPTION_ID" \
    --workspace-name "$GRAFANA_NAME" \
    --name "$MPE_NAME" \
    --query id \
    -o tsv 2>/dev/null | strip_carriage_returns || echo "")

if [[ -n "$EXISTING_MPE" ]]; then
    echo "✓ Managed Private Endpoint '$MPE_NAME' already exists"
    echo "  Skipping creation and proceeding to connection approval..."
else
    echo "[4/6] Creating Managed Private Endpoint..."
    az grafana managed-private-endpoint create \
        --resource-group "$GRAFANA_RG" \
        --workspace-name "$GRAFANA_NAME" \
        --subscription "$SUBSCRIPTION_ID" \
        --location "$GRAFANA_REGION" \
        --name "$MPE_NAME" \
        --group-ids mysqlServer \
        --private-link-resource-id "$MYSQL_ID" \
        --private-link-resource-region "$MYSQL_REGION"
    echo "✓ Managed Private Endpoint created"
fi

MPE_PRIVATE_ENDPOINT_ID=$(az grafana managed-private-endpoint show \
    --resource-group "$GRAFANA_RG" \
    --subscription "$SUBSCRIPTION_ID" \
    --workspace-name "$GRAFANA_NAME" \
    --name "$MPE_NAME" \
    --query properties.privateEndpoint.id \
    -o tsv 2>/dev/null | strip_carriage_returns)
if [[ -z "$MPE_PRIVATE_ENDPOINT_ID" ]]; then
    echo "ERROR: Could not determine the private endpoint resource ID for Managed Private Endpoint '$MPE_NAME'"
    exit 1
fi

echo "[5/6] Waiting for pending connection request..."
CONNECTION_NAME=""
CONNECTION_STATUS=""
TIMEOUT=300  # 5 minutes
ELAPSED=0
INTERVAL=10

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if ! CONNECTIONS_JSON=$(az network private-endpoint-connection list \
        --id "$MYSQL_ID" \
        -o json 2>/dev/null | strip_carriage_returns); then
        CONNECTIONS_JSON=""
    fi

    CONNECTION_ID=""
    if [[ -n "$CONNECTIONS_JSON" ]]; then
        CONNECTION_ID=$(echo "$CONNECTIONS_JSON" | jq -r \
            --arg private_endpoint_id "$MPE_PRIVATE_ENDPOINT_ID" \
            '[.[] | select(.properties.privateEndpoint.id == $private_endpoint_id)] | .[0].id // empty')
    fi

    if [[ -n "$CONNECTION_ID" ]]; then
        CONNECTION_NAME="${CONNECTION_ID##*/}"
        CONNECTION_STATUS=$(echo "$CONNECTIONS_JSON" | jq -r \
            --arg connection_id "$CONNECTION_ID" \
            '.[] | select(.id == $connection_id) | .properties.privateLinkServiceConnectionState.status // empty')
        echo "✓ Found connection for MPE '$MPE_NAME': $CONNECTION_NAME ($CONNECTION_STATUS)"

        if [[ "$CONNECTION_STATUS" == "Approved" ]]; then
            echo "  ✓ Connection is already approved; continuing..."
            break
        elif [[ "$CONNECTION_STATUS" == "Pending" ]]; then
            echo "  Connection is pending approval"
            break
        elif [[ -n "$CONNECTION_STATUS" ]]; then
            echo "ERROR: Connection for MPE '$MPE_NAME' is in unexpected state '$CONNECTION_STATUS'"
            exit 1
        fi
    fi

    ELAPSED=$((ELAPSED + INTERVAL))
    REMAINING=$((TIMEOUT - ELAPSED))
    echo "  Waiting... ($REMAINING seconds remaining)"
    sleep "$INTERVAL"
done

if [[ -z "$CONNECTION_NAME" ]]; then
    echo "ERROR: No connection found for MPE '$MPE_NAME' after ${TIMEOUT}s timeout"
    echo "HINT: Check that the managed private endpoint request was created"
    exit 1
fi

if [[ "$CONNECTION_STATUS" == "Pending" ]]; then
    echo "[6/6] Approving connection..."
    az network private-endpoint-connection approve \
        --resource-group "$MYSQL_RG" \
        --subscription "$MYSQL_SUBSCRIPTION_ID" \
        --type Microsoft.DBforMySQL/flexibleServers \
        --resource-name "$MYSQL_SERVER" \
        --name "$CONNECTION_NAME" \
        --description "Approved for Azure Managed Grafana"
    echo "✓ Connection approved"
else
    echo "[6/6] Connection already approved; skipping approval"
fi

# Verify final state
echo ""
echo "Verifying connection state..."
FINAL_STATE=$(az network private-endpoint-connection show \
    --resource-group "$MYSQL_RG" \
    --subscription "$MYSQL_SUBSCRIPTION_ID" \
    --type Microsoft.DBforMySQL/flexibleServers \
    --resource-name "$MYSQL_SERVER" \
    --name "$CONNECTION_NAME" \
    --query properties.privateLinkServiceConnectionState.status \
    -o tsv | strip_carriage_returns)

if [[ "$FINAL_STATE" == "Approved" ]]; then
    echo "✓ Connection state: $FINAL_STATE"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SUCCESS: Private endpoint is ready for Grafana datasource"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
else
    echo "ERROR: Connection state is '$FINAL_STATE' (expected 'Approved')"
    exit 1
fi