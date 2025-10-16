#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RESOURCE_GROUP_NAME=$1
USER_ASSIGNED_IDENTITY_NAME=$2
if [ -z "$RESOURCE_GROUP_NAME" ] || [ -z "$USER_ASSIGNED_IDENTITY_NAME" ]; then
  echo "Usage: $0 <resource-group-name> <user-assigned-identity-name>"
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

# Create the DCR
# Get current subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create the DCR file with the correct location and monitoring account
# Get the monitoring account resource ID from the outputs file
MONITORING_ACCOUNT_ID=$(jq -r '.properties.outputResources[2].id' $THIS_DIR/outputs.json)
if [ -z "$MONITORING_ACCOUNT_ID" ]; then
  echo "Failed to retrieve Monitoring Account ID."
  exit 1
fi
# using the templates/dcr.json file, update the location and monitoring account id
jq --arg location "$LOCATION" --arg monitoringAccountId "$MONITORING_ACCOUNT_ID" '
    .location = $location |
    .properties.destinations.monitoringAccounts[0].accountResourceId = $monitoringAccountId
' $THIS_DIR/templates/dcr.json > $THIS_DIR/dcr.json
if [ $? -ne 0 ]; then
  echo "Failed to update DCR file."
  exit 1
fi

echo "Creating Data Collection Rule..."
az rest --method put --url https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Insights/dataCollectionRules/dcrCycleCloudMonitoring?api-version=2024-03-11 --body "@$THIS_DIR/dcr.json" > $THIS_DIR/dcr_output.json
if [ $? -ne 0 ]; then
  echo "Failed to create Data Collection Rule."
  exit 1
fi

# Create the Policy Assignment parameters file with the correct DCR ID
DCR_ID=$(jq -r '.id' $THIS_DIR/dcr_output.json)
if [ -z "$DCR_ID" ]; then
  echo "Failed to retrieve DCR ID."
  exit 1
fi

# Retrieve the client ID of the user assigned managed identity
echo "Retrieving client ID for user assigned managed identity: $USER_ASSIGNED_IDENTITY_NAME..."
USER_ASSIGNED_IDENTITY_CLIENT_ID=$(az identity show --name "$USER_ASSIGNED_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query clientId -o tsv)
if [ -z "$USER_ASSIGNED_IDENTITY_CLIENT_ID" ]; then
  echo "Failed to retrieve client ID for user assigned managed identity: $USER_ASSIGNED_IDENTITY_NAME"
  echo "Please ensure the identity exists in resource group: $RESOURCE_GROUP_NAME"
  exit 1
fi
echo "Retrieved client ID: $USER_ASSIGNED_IDENTITY_CLIENT_ID"

jq --arg dcrId "$DCR_ID" --arg clientId "$USER_ASSIGNED_IDENTITY_CLIENT_ID" '
    .dcrResourceId.value = $dcrId |
    .userAssignedManagedIdentityClientId.value = $clientId
' $THIS_DIR/templates/policy_assign_parameters.json > $THIS_DIR/parameters.json

if [ $? -ne 0 ]; then
  echo "Failed to update Policy Assignment parameters file."
  exit 1
fi
echo "Creating Policy Assignment..."

# Monitoring Metrics Publisher, Contributor, Monitoring Contributor, Log Analytics Contributor

az policy assignment create \
  --name "DeployAMAForCycleCloudAssignment-$RESOURCE_GROUP_NAME" \
  --display-name "Deploy AMA for CycleCloud Assignment for $RESOURCE_GROUP_NAME" \
  --policy-set-definition "DeployAMAForCycleCloud" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME" \
  --mi-system-assigned \
  --identity-scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME" \
  --location "$LOCATION" \
  --role 'Contributor' \
  --params "@$THIS_DIR/parameters.json"

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Assignment."
  exit 1
fi
