#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$THIS_DIR/util.sh"

# Parse arguments
SLURM_FLAG=""
RESOURCE_GROUP_NAME=""
ENABLE_MYSQL=false
MYSQL_SERVER=""
MYSQL_RG=""
MYSQL_USERNAME=""
MYSQL_PASSWORD=""
MYSQL_DB_NAME=""
MYSQL_DATASOURCE_NAME=""
MYSQL_PORT="3306"
MYSQL_CA_CERT_FILE=""
USER_OBJECT_ID=""

usage() {
  echo "Usage: $0 <resource-group-name> [--user-object-id <object-id>] [--slurm] [--mysql --mysql-rg <resource-group> --mysql-server <server> --mysql-username <user>]"
  echo "  Optional MySQL flags: --mysql-database <name> --mysql-port <port> --mysql-datasource-name <name>"
  echo "                       --mysql-ca-cert-file <path>"
  echo "  --user-object-id <object-id>: Optional deployment identity object ID; defaults to the signed-in user."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --slurm)
      SLURM_FLAG="--slurm"
      shift
      ;;
    --mysql)
      ENABLE_MYSQL=true
      shift
      ;;
    --user-object-id)
        require_option_value "$@"
      USER_OBJECT_ID="$2"
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
    --mysql-username)
        require_option_value "$@"
      MYSQL_USERNAME="$2"
      shift 2
      ;;
    --mysql-database)
        require_option_value "$@"
      MYSQL_DB_NAME="$2"
      shift 2
      ;;
    --mysql-port)
        require_option_value "$@"
      MYSQL_PORT="$2"
      shift 2
      ;;
    --mysql-datasource-name)
        require_option_value "$@"
      MYSQL_DATASOURCE_NAME="$2"
      shift 2
      ;;
    --mysql-ca-cert-file)
        require_option_value "$@"
      MYSQL_CA_CERT_FILE="$2"
      shift 2
      ;;
    -*|"")
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [ -n "$RESOURCE_GROUP_NAME" ]; then
        echo "Unexpected argument: $1"
        usage
        exit 1
      fi
      RESOURCE_GROUP_NAME="$1"
      shift
      ;;
  esac
done

if [ -z "$RESOURCE_GROUP_NAME" ]; then
  usage
  exit 1
fi

# Retrieve the location of the resource group
LOCATION=$(az group show -n "$RESOURCE_GROUP_NAME" --query location -o tsv 2>/dev/null | strip_carriage_returns)
if [ -z "$LOCATION" ]; then
  echo "Resource group $RESOURCE_GROUP_NAME does not exist."
  echo "Please create the resource group first."
  echo "az group create --name $RESOURCE_GROUP_NAME --location <location>"
  exit 1
fi

# Retrieve the signed-in user's object ID when one was not provided
if [ -z "$USER_OBJECT_ID" ]; then
  USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
  if [ -z "$USER_OBJECT_ID" ]; then
    echo "Failed to retrieve user object ID."
    exit 1
  fi
fi

if [ "$ENABLE_MYSQL" = true ]; then
  if [ -z "$MYSQL_RG" ] || [ -z "$MYSQL_SERVER" ] || [ -z "$MYSQL_USERNAME" ]; then
    echo "MySQL mode requires: --mysql-rg, --mysql-server, and --mysql-username"
    exit 1
  fi

  read -r -s -p "Enter MySQL password: " MYSQL_PASSWORD
  echo
  if [ -z "$MYSQL_PASSWORD" ]; then
    echo "MySQL password is required."
    exit 1
  fi
fi

deploymentName="monitoring-deployment-$(date +%s)"
# Start the deployment
az deployment group create \
  --resource-group "$RESOURCE_GROUP_NAME" \
  -o json \
  -n "$deploymentName" \
  --template-file "$THIS_DIR/main.bicep" \
  --parameters location="$LOCATION" userObjectId="$USER_OBJECT_ID" \
  > "$THIS_DIR/outputs.json"
if [ $? -ne 0 ]; then
  echo "Deployment failed."
  exit 1
fi

# Check if the deployment was successful
if grep -q '"provisioningState": "Succeeded"' "$THIS_DIR/outputs.json"; then
  echo "Deployment succeeded."
else
  echo "Deployment failed."
  exit 1
fi

GRAFANA_NAME=$(jq -r '.properties.outputs.grafanaName.value' "$THIS_DIR/outputs.json")
if [ -z "$GRAFANA_NAME" ] || [ "$GRAFANA_NAME" = "null" ]; then
  echo "Failed to retrieve Grafana name."
  exit 1
fi

DASHBOARD_ARGS=("$RESOURCE_GROUP_NAME" "$GRAFANA_NAME")
if [ -n "$SLURM_FLAG" ]; then
  DASHBOARD_ARGS+=("$SLURM_FLAG")
fi
if ! "$THIS_DIR/add_dashboards.sh" "${DASHBOARD_ARGS[@]}"; then
  echo "Failed to configure Grafana dashboards."
  exit 1
fi

if [ "$ENABLE_MYSQL" = true ]; then
  bash "$THIS_DIR/add_mysql_networking.sh" \
    --grafana-rg "$RESOURCE_GROUP_NAME" \
    --grafana-name "$GRAFANA_NAME" \
    --mysql-rg "$MYSQL_RG" \
    --mysql-server "$MYSQL_SERVER"
  if [ $? -ne 0 ]; then
    echo "Failed to configure MySQL private endpoint networking."
    exit 1
  fi

  DATASOURCE_ARGS=(
    --resource-group "$RESOURCE_GROUP_NAME"
    --grafana-name "$GRAFANA_NAME"
    --mysql-rg "$MYSQL_RG"
    --mysql-server "$MYSQL_SERVER"
    --mysql-port "$MYSQL_PORT"
    --mysql-database "$MYSQL_DB_NAME"
    --mysql-username "$MYSQL_USERNAME"
    --mysql-password-stdin
  )

  if [ -n "$MYSQL_DATASOURCE_NAME" ]; then
    DATASOURCE_ARGS+=(--datasource-name "$MYSQL_DATASOURCE_NAME")
  fi
  if [ -n "$MYSQL_CA_CERT_FILE" ]; then
    DATASOURCE_ARGS+=(--mysql-ca-cert-file "$MYSQL_CA_CERT_FILE")
  fi

  printf '%s\n' "$MYSQL_PASSWORD" | bash "$THIS_DIR/add_mysql_datasource.sh" "${DATASOURCE_ARGS[@]}"
  if [ $? -ne 0 ]; then
    echo "Failed to configure MySQL datasource in Grafana."
    exit 1
  fi

  echo "MySQL datasource setup completed using server $MYSQL_SERVER"
fi
