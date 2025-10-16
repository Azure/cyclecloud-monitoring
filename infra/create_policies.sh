#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Get current subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "Failed to retrieve subscription ID. Please ensure you are logged in to Azure CLI."
  exit 1
fi

echo "Creating policies in subscription: $SUBSCRIPTION_ID"

# Create Policy Definition for VMs
echo "Creating Policy Definition for CycleCloud VMs..."
az policy definition create \
  --name "DeployAMAForCycleCloudVMs" \
  --display-name "Deploy Azure Monitor Agent and Associate Data Collection Rules with CycleCloud VMs" \
  --rules $THIS_DIR/templates/policy_definition_VM.json \
  --params $THIS_DIR/templates/policy_parameters.json \
  --mode Indexed \
  --subscription $SUBSCRIPTION_ID 

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Definition for VMs."
  exit 1
fi

# Create Policy Definition for VMSS
echo "Creating Policy Definition for CycleCloud VMSS..."
az policy definition create \
  --name "DeployAMAForCycleCloudVMSS" \
  --display-name "Deploy Azure Monitor Agent and Associate Data Collection Rules with CycleCloud VMSS" \
  --rules $THIS_DIR/templates/policy_definition_VMSS.json \
  --params $THIS_DIR/templates/policy_parameters.json \
  --mode Indexed \
  --subscription $SUBSCRIPTION_ID

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Definition for VMSS."
  exit 1
fi

# Build the definitions.json file with the correct subscription ID
echo "Building policy set definitions file..."
sed "s/SUBSCRIPTION_ID/$SUBSCRIPTION_ID/g" $THIS_DIR/templates/definitions.json > $THIS_DIR/definitions.json
if [ $? -ne 0 ]; then
  echo "Failed to update definitions file."
  exit 1
fi

# Create Policy Set Definition (Initiative)
echo "Creating Policy Set Definition..."
az policy set-definition create \
  --name "DeployAMAForCycleCloud" \
  --display-name "CycleCloud Monitoring Initiative" \
  --description "Applies multiple policies for CycleCloud monitoring" \
  --definitions "@$THIS_DIR/definitions.json" \
  --params "{ \"dcrResourceId\": {\"type\": \"String\"}, \"userAssignedManagedIdentityClientId\": {\"type\": \"String\", \"defaultValue\": \"\"} }" \
  --subscription $SUBSCRIPTION_ID

if [ $? -ne 0 ]; then
  echo "Failed to create Policy Set Definition."
  exit 1
fi

echo "Successfully created all policy definitions and policy set definition!"
echo "Policy definitions created:"
echo "  - DeployAMAForCycleCloudVMs"
echo "  - DeployAMAForCycleCloudVMSS"
echo "Policy set definition created:"
echo "  - DeployAMAForCycleCloud"