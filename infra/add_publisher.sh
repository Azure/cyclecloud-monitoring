#!/bin/bash
# Grant the role ‘Monitoring Metrics Publisher’ to a managed identity
# for the Data Collection Rule of the Managed Monitor Workspace
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
UMI_RG_NAME=$1
UMI_NAME=$2

function usage() {
  echo "Usage: $0 <user-managed-identity-resource-group> <user-managed-identity-name>"
}

if [ -z "$UMI_NAME" ]; then
    usage
    exit 1
fi
if [ -z "$UMI_RG_NAME" ]; then
    usage
    exit 1
fi

UMI_PID=$(az identity show -n $UMI_NAME -g $UMI_RG_NAME --query 'principalId' -o tsv)
if [ -z "$UMI_PID" ]; then
  echo "Failed to retrieve User Managed Identity principal ID."
  exit 1
fi

DCR_ID=$(jq -r '.properties.outputs.dcrResourceId.value' $THIS_DIR/outputs.json)
if [ -z "$DCR_ID" ]; then
  echo "Failed to retrieve DCR ID."
  exit 1
fi

az role assignment create --role 'Monitoring Metrics Publisher' \
                              --assignee ${UMI_PID} \
                              --scope ${DCR_ID}
if [ $? -ne 0 ]; then
  echo "Failed to assign role to User Managed Identity."
  exit 1
fi
