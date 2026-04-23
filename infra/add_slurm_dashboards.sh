#!/bin/bash
set -e

RESOURCE_GROUP_NAME=$1
GRAFANA_NAME=$2
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
