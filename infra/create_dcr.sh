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

# Create Policy Definition and Assignment
echo "Creating Policy Definition for CycleCloud VMs..."
az policy definition create \
  --name "DeployAMAForCycleCloudVMs" \
  --display-name "Deploy Azure Monitor Agent and Associate Data Collection Rules with CycleCloud VMs" \
  --rules $THIS_DIR/templates/policy_definition_VM.json \
  --params $THIS_DIR/templates/policy_parameters.json \
  --mode Indexed \
  --subscription $SUBSCRIPTION_ID 

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Definition."
  exit 1
fi

echo "Creating Policy Definition for CycleCloud VMSS..."
az policy definition create \
  --name "DeployAMAForCycleCloudVMSS" \
  --display-name "Deploy Azure Monitor Agent and Associate Data Collection Rules with CycleCloud VMSS" \
  --rules $THIS_DIR/templates/policy_definition_VMSS.json \
  --params $THIS_DIR/templates/policy_parameters.json \
  --mode Indexed \
  --subscription $SUBSCRIPTION_ID

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Definition."
  exit 1
fi

# Create the Policy Assignment parameters file with the correct DCR ID
DCR_ID=$(jq -r '.id' $THIS_DIR/dcr_output.json)
if [ -z "$DCR_ID" ]; then
  echo "Failed to retrieve DCR ID."
  exit 1
fi
jq --arg dcrId "$DCR_ID" '
    .dcrResourceId.value = $dcrId
' $THIS_DIR/templates/policy_assign_parameters.json > $THIS_DIR/parameters.json

if [ $? -ne 0 ]; then
  echo "Failed to update Policy Assignment parameters file."
  exit 1
fi

# Build the definitions.json file with the correct subscription ID
sed "s/SUBSCRIPTION_ID/$SUBSCRIPTION_ID/g" $THIS_DIR/templates/definitions.json > $THIS_DIR/definitions.json
if [ $? -ne 0 ]; then
  echo "Failed to update definitions file."
  exit 1
fi

# Create Policy Set Definition
echo "Creating Policy Set Definition..."
az policy set-definition create \
  --name "DeployAMAForCycleCloud" \
  --display-name "CycleCloud Monitoring Initiative" \
  --description "Applies multiple policies for CycleCloud monitoring" \
  --definitions "@$THIS_DIR/definitions.json" \
  --params "{ \"dcrResourceId\": {\"type\": \"String\"} }" \
  --subscription $SUBSCRIPTION_ID

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Set Definition."
  exit 1
fi


echo "Creating Policy Assignment..."

# Monitoring Metrics Publisher, Contributor, Monitoring Contributor, Log Analytics Contributor

az policy assignment create \
  --name "DeployAMAForCycleCloudAssignment" \
  --display-name "Deploy AMA for CycleCloud Assignment" \
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
