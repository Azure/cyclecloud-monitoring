#!/bin/bash
set -e

RESOURCE_GROUP_NAME=$1
GRAFANA_NAME=$2
TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# Branch of cyclecloud-slurm to pull dashboards from
BRANCH="azreenzaman/dashboard-changes"
# GitHub replaces "/" with "-" in the archive's extracted directory name
BRANCH_DIR_NAME="${BRANCH//\//-}"

TARBALL_PATH="$TEMP_DIR/cyclecloud-slurm.tar.gz"
EXTRACTED_DIR="$TEMP_DIR/cyclecloud-slurm-${BRANCH_DIR_NAME}"
curl --fail --location --silent --show-error -o "$TARBALL_PATH" https://github.com/Azure/cyclecloud-slurm/archive/refs/heads/${BRANCH}.tar.gz
tar -xzf "$TARBALL_PATH" -C "$TEMP_DIR"
if [ ! -d "$EXTRACTED_DIR/azure-slurm-exporter" ]; then
  echo "azure-slurm-exporter directory not found in release. Skipping."
else
  cd "$EXTRACTED_DIR/azure-slurm-exporter"
  chmod +x add_dashboards.sh
  ./add_dashboards.sh $RESOURCE_GROUP_NAME $GRAFANA_NAME
fi
