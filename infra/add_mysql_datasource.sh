#!/bin/bash
set -euo pipefail

# Script: add_mysql_datasource.sh
# Purpose: Create a MySQL datasource in Azure Managed Grafana via REST API
# Usage: echo "password" | ./add_mysql_datasource.sh --resource-group <rg> --grafana-name <name> \
#          [--datasource-name <name>] --mysql-rg <rg> --mysql-server <server> \
#          [--mysql-database <db>] --mysql-username <user> \
#          --mysql-password-stdin [--mysql-port <port>] [--mysql-ca-cert-file <path>]

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$THIS_DIR/util.sh"

# Check jq availability upfront
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found in PATH"
    exit 1
fi

# Parse arguments
RESOURCE_GROUP=""
GRAFANA_NAME=""
DATASOURCE_NAME=""
MYSQL_HOST=""
MYSQL_SERVER=""
MYSQL_RG=""
MYSQL_PORT="3306"
MYSQL_DATABASE=""
MYSQL_USERNAME=""
MYSQL_PASSWORD_STDIN=false
MYSQL_CA_CERT_FILE=""
MYSQL_CA_CERT_SOURCE=""
CERT_TEMP_DIR=""
PAYLOAD_FILE=""

cleanup() {
    if [[ -n "$CERT_TEMP_DIR" ]]; then
        rm -rf "$CERT_TEMP_DIR"
    fi
    if [[ -n "$PAYLOAD_FILE" ]]; then
        rm -f "$PAYLOAD_FILE"
    fi
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --resource-group)
            require_option_value "$@"
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --grafana-name)
            require_option_value "$@"
            GRAFANA_NAME="$2"
            shift 2
            ;;
        --datasource-name)
            require_option_value "$@"
            DATASOURCE_NAME="$2"
            shift 2
            ;;
        --mysql-server)
            require_option_value "$@"
            MYSQL_SERVER="$2"
            shift 2
            ;;
        --mysql-rg)
            require_option_value "$@"
            MYSQL_RG="$2"
            shift 2
            ;;
        --mysql-port)
            require_option_value "$@"
            MYSQL_PORT="$2"
            shift 2
            ;;
        --mysql-database)
            require_option_value "$@"
            MYSQL_DATABASE="$2"
            shift 2
            ;;
        --mysql-username)
            require_option_value "$@"
            MYSQL_USERNAME="$2"
            shift 2
            ;;
        --mysql-password-stdin)
            MYSQL_PASSWORD_STDIN=true
            shift
            ;;
        --mysql-ca-cert-file)
            require_option_value "$@"
            MYSQL_CA_CERT_FILE="$2"
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

# Validate required arguments
MISSING_ARGS=()
[[ -z "$RESOURCE_GROUP" ]] && MISSING_ARGS+=("--resource-group")
[[ -z "$GRAFANA_NAME" ]] && MISSING_ARGS+=("--grafana-name")
[[ -z "$MYSQL_RG" ]] && MISSING_ARGS+=("--mysql-rg")
[[ -z "$MYSQL_SERVER" ]] && MISSING_ARGS+=("--mysql-server")
[[ -z "$MYSQL_USERNAME" ]] && MISSING_ARGS+=("--mysql-username")

if [ ${#MISSING_ARGS[@]} -gt 0 ]; then
    echo "ERROR: Missing required arguments: ${MISSING_ARGS[*]}"
    echo ""
    echo "Usage: echo 'password' | $0 \\"
    echo "  --resource-group <rg> \\"
    echo "  --grafana-name <name> \\"
    echo "  [--datasource-name <name>] \\"
    echo "  --mysql-rg <rg> \\"
    echo "  --mysql-server <server> \\"
    echo "  [--mysql-database <db>] \\"
    echo "  --mysql-username <user> \\"
    echo "  --mysql-password-stdin \\"
    echo "  [--mysql-port <port>] \\"
    echo "  [--mysql-ca-cert-file <path>]"
    exit 1
fi

if [[ "$MYSQL_PASSWORD_STDIN" != true ]]; then
    echo "ERROR: MySQL password must be provided via stdin using --mysql-password-stdin"
    exit 1
fi

# Read the password before running external commands that could consume stdin.
MYSQL_PASSWORD=$(cat)
if [[ -z "$MYSQL_PASSWORD" ]]; then
    echo "ERROR: MySQL password from stdin was empty"
    exit 1
fi

if ! MYSQL_HOST=$(az mysql flexible-server show \
    --resource-group "$MYSQL_RG" \
    --name "$MYSQL_SERVER" \
    --query fullyQualifiedDomainName \
    -o tsv 2>/dev/null | strip_carriage_returns); then
    echo "ERROR: Could not retrieve MySQL server '$MYSQL_SERVER' from resource group '$MYSQL_RG'"
    exit 1
fi
if [[ -z "$MYSQL_HOST" ]]; then
    echo "ERROR: MySQL server '$MYSQL_SERVER' has no fully qualified domain name"
    exit 1
fi

if [[ -z "$DATASOURCE_NAME" ]]; then
    DATASOURCE_NAME="$MYSQL_HOST"
fi
DATASOURCE_NAME_URI=$(jq -nr --arg value "$DATASOURCE_NAME" '$value | @uri')

# Resolve the CA certificate. An explicit file takes precedence; otherwise extract
# AzureCA_<version>.pem from a pinned cyclecloud-slurm install package.
MYSQL_CA_CERT=""
if [[ -n "$MYSQL_CA_CERT_FILE" ]]; then
    if [[ ! -f "$MYSQL_CA_CERT_FILE" ]]; then
        echo "ERROR: CA certificate file not found: $MYSQL_CA_CERT_FILE"
        exit 1
    fi
    echo "Reading CA certificate from: $MYSQL_CA_CERT_FILE"
    MYSQL_CA_CERT=$(cat "$MYSQL_CA_CERT_FILE")
    if [[ -z "$MYSQL_CA_CERT" ]]; then
        echo "ERROR: CA certificate file is empty: $MYSQL_CA_CERT_FILE"
        exit 1
    fi
    MYSQL_CA_CERT_SOURCE="$MYSQL_CA_CERT_FILE"
else
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl is required to download the default AzureCA certificate"
        exit 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
        echo "ERROR: tar is required to extract the default AzureCA certificate"
        exit 1
    fi
    EXPECTED_CERT_NAME="AzureCA_${CYCLECLOUD_SLURM_VERSION}"
    EXPECTED_PACKAGE_NAME="azure-slurm-install-pkg-${CYCLECLOUD_SLURM_VERSION}.tar.gz"

    CERT_TEMP_DIR=$(mktemp -d)
    CERT_ARCHIVE="$CERT_TEMP_DIR/$EXPECTED_PACKAGE_NAME"
    if ! download_cyclecloud_slurm_install_package "$CERT_ARCHIVE"; then
        echo "ERROR: Failed to download pinned install package '$EXPECTED_PACKAGE_NAME'"
        exit 1
    fi

    if ! MYSQL_CA_CERT=$(tar -xOf "$CERT_ARCHIVE" "azure-slurm-install/$EXPECTED_CERT_NAME.pem"); then
        echo "ERROR: Certificate '$EXPECTED_CERT_NAME.pem' was not found in '$EXPECTED_PACKAGE_NAME'"
        exit 1
    fi
    if [[ -z "$MYSQL_CA_CERT" ]]; then
        echo "ERROR: Certificate '$EXPECTED_CERT_NAME.pem' in '$EXPECTED_PACKAGE_NAME' is empty"
        exit 1
    fi
    MYSQL_CA_CERT_SOURCE="cyclecloud-slurm $CYCLECLOUD_SLURM_VERSION ($EXPECTED_PACKAGE_NAME: $EXPECTED_CERT_NAME.pem)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MySQL Datasource Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Grafana: $GRAFANA_NAME (rg: $RESOURCE_GROUP)"
echo "MySQL:   $MYSQL_HOST:$MYSQL_PORT / $MYSQL_DATABASE"
echo "User:    $MYSQL_USERNAME"
echo "Source:  stdin (password masked)"
echo "TLS:     Enabled with CA certificate validation"
echo "CA:      $MYSQL_CA_CERT_SOURCE"
echo ""

# Verify Grafana workspace exists
echo "[1/4] Verifying Grafana workspace exists..."
if ! az grafana show \
    --name "$GRAFANA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    &>/dev/null; then
    echo "ERROR: Grafana workspace '$GRAFANA_NAME' not found in resource group '$RESOURCE_GROUP'"
    exit 1
fi
echo "✓ Grafana workspace found"

# Get Grafana endpoint
echo "[2/4] Retrieving Grafana endpoint..."
GRAFANA_ENDPOINT=$(az grafana show \
    -n "$GRAFANA_NAME" \
    -g "$RESOURCE_GROUP" \
    --query properties.endpoint \
    -o tsv | strip_carriage_returns)

if [[ -z "$GRAFANA_ENDPOINT" ]]; then
    echo "ERROR: Failed to retrieve Grafana endpoint"
    exit 1
fi
echo "✓ Grafana endpoint: $GRAFANA_ENDPOINT"

# Check if datasource already exists
echo "[3/4] Checking if datasource already exists..."
if az rest --method get \
    --url "$GRAFANA_ENDPOINT/api/datasources/name/$DATASOURCE_NAME_URI" \
    --resource "$GRAFANA_AAD_RESOURCE" \
    &>/dev/null; then
    echo "✓ Datasource '$DATASOURCE_NAME' already exists"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "SKIPPED: Datasource already configured"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

# Create datasource payload
echo "[4/4] Creating datasource..."

# Build secure JSON data with CA certificate validation.
PAYLOAD_FILE=$(mktemp)
chmod 600 "$PAYLOAD_FILE"
printf '%s' "$MYSQL_PASSWORD" | jq -Rs \
    --arg name "$DATASOURCE_NAME" \
    --arg hostport "$MYSQL_HOST:$MYSQL_PORT" \
    --arg database "$MYSQL_DATABASE" \
    --arg user "$MYSQL_USERNAME" \
    --arg caCert "$MYSQL_CA_CERT" \
    '. as $password | {
        name: $name,
        type: "mysql",
        access: "proxy",
        url: $hostport,
        database: $database,
        user: $user,
        isDefault: false,
        jsonData: {
            tlsAuth: false,
            tlsAuthWithCACert: true,
            tlsSkipVerify: false,
            maxOpenConns: 100,
            maxIdleConns: 100,
            connMaxLifetime: 14400
        },
        secureJsonData: {
            password: $password,
            tlsCACert: $caCert
        }
    }' > "$PAYLOAD_FILE"

# Submit datasource creation request
if ! RESPONSE=$(az rest --method post \
    --url "$GRAFANA_ENDPOINT/api/datasources" \
    --resource "$GRAFANA_AAD_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body @"$PAYLOAD_FILE" 2>&1); then
    echo "ERROR: Failed to create datasource via Grafana API"
    echo "Response: $RESPONSE"
    exit 1
fi

# Verify datasource was created successfully
DATASOURCE_ID=$(echo "$RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
if [[ -z "$DATASOURCE_ID" ]]; then
    echo "ERROR: Datasource creation succeeded but no ID returned"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✓ Datasource created with ID: $DATASOURCE_ID"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUCCESS: MySQL datasource is ready to use"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
