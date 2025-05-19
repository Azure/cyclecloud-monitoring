#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RESOURCE_GROUP_NAME=$1
if [ -z "$RESOURCE_GROUP_NAME" ]; then
  echo "Usage: $0 <resource-group-name>"
  exit 1
fi

# Retrieve the location of the resource group
LOCATION=$(az group show -n $RESOURCE_GROUP_NAME --query location -o tsv 2>/dev/null | tr -d '\n' | tr -d '\r') 
if [ -z "$LOCATION" ]; then
  echo "Resource group $RESOURCE_GROUP_NAME does not exist."
  echo "Please create the resource group first."
  echo "az group create --name $RESOURCE_GROUP_NAME --location <location>"
  exit 1
fi

# Retrieve the user object id of the current user doing the deployment
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
if [ -z "$USER_OBJECT_ID" ]; then
  echo "Failed to retrieve user object ID."
  exit 1
fi

az deployment group create --resource-group $RESOURCE_GROUP_NAME --template-file $THIS_DIR/main.bicep --parameters location=$LOCATION userObjectId=$USER_OBJECT_ID > $THIS_DIR/outputs.json
if [ $? -ne 0 ]; then
  echo "Deployment failed."
  exit 1
fi
# Check if the deployment was successful
if grep -q '"provisioningState": "Succeeded"' $THIS_DIR/outputs.json; then
  echo "Deployment succeeded."
else
  echo "Deployment failed."
  exit 1
fi

GRAFANA_NAME=$(jq -r '.properties.outputs.grafanaName.value' $THIS_DIR/outputs.json)
if [ -z "$GRAFANA_NAME" ]; then
  echo "Failed to retrieve Grafana name."
  exit 1
fi
$THIS_DIR/add_dashboards.sh $RESOURCE_GROUP_NAME $GRAFANA_NAME

