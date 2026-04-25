#!/bin/bash
set -e

RESOURCE_GROUP_NAME=$1
GRAFANA_NAME=$2

if [ -z "$GRAFANA_NAME" ]; then
  echo "Usage: $0 <resource-group-name> <grafana-name>"
  exit 1
fi
if [ -z "$RESOURCE_GROUP_NAME" ]; then
  echo "Usage: $0 <resource-group-name> <grafana-name>"
  exit 1
fi

FOLDER_NAME="Azure CycleCloud"
# Create Grafana dashboards folders
if ! az grafana folder show -n $GRAFANA_NAME -g $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" > /dev/null 2>&1; then
  echo "$FOLDER_NAME folder does not exist. Creating it."
  az grafana folder create --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --title "$FOLDER_NAME"
fi

TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# Get the latest release tag of cyclecloud-slurm
LATEST_TAG=$(curl --fail --silent --show-error https://api.github.com/repos/Azure/cyclecloud-slurm/releases/latest | jq -r '.tag_name // empty')
if [ -z "$LATEST_TAG" ]; then
  echo "Failed to determine latest cyclecloud-slurm release tag."
  exit 1
fi

TARBALL_PATH="$TEMP_DIR/cyclecloud-slurm.tar.gz"
EXTRACTED_DIR="$TEMP_DIR/cyclecloud-slurm-${LATEST_TAG}"
curl --fail --location --silent --show-error -o "$TARBALL_PATH" https://github.com/Azure/cyclecloud-slurm/archive/refs/tags/${LATEST_TAG}.tar.gz
tar -xzf "$TARBALL_PATH" -C "$TEMP_DIR"
if [ ! -d "$EXTRACTED_DIR/azure-slurm-exporter" ]; then
  echo "azure-slurm-exporter directory not found in release. Skipping."
else
  cd "$EXTRACTED_DIR/azure-slurm-exporter"
  chmod +x add_dashboards.sh
  ./add_dashboards.sh $RESOURCE_GROUP_NAME $GRAFANA_NAME
fi
