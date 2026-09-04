#!/bin/bash
set -e

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$THIS_DIR/util.sh"

RESOURCE_GROUP_NAME=$1
GRAFANA_NAME=$2
TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

TARBALL_PATH="$TEMP_DIR/cyclecloud-slurm.tar.gz"
EXTRACTED_DIR="$TEMP_DIR/cyclecloud-slurm-${CYCLECLOUD_SLURM_VERSION}"
download_cyclecloud_slurm_source_archive "$TARBALL_PATH"
tar -xzf "$TARBALL_PATH" -C "$TEMP_DIR"
if [ ! -d "$EXTRACTED_DIR/azure-slurm-exporter" ]; then
  echo "azure-slurm-exporter directory not found in release. Skipping."
else
  cd "$EXTRACTED_DIR/azure-slurm-exporter"
  chmod +x add_dashboards.sh
  ./add_dashboards.sh $RESOURCE_GROUP_NAME $GRAFANA_NAME
fi
