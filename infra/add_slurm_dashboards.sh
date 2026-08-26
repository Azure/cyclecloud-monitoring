#!/bin/bash
set -e

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$THIS_DIR/util.sh"

RESOURCE_GROUP_NAME=$1
GRAFANA_NAME=$2
TEMP_DIR=$(mktemp -d)
FOLDER_NAME="Azure CycleCloud"
SLURM_BUTTONS_PANEL_REL_PATH="azure-slurm-exporter/dashboards/library-panels/azslurm-dashboard-buttons.json"
NODE_BUTTONS_PANEL_FILE="$THIS_DIR/dashboards/library-panels/node_dashboard_buttons.json"
NODE_BUTTONS_UID="cfo8upic84lxce"
TARGET_DASHBOARDS=(
  "node_level.json"
  "gpu_level.json"
  "cluster_nodearray_overview.json"
)

add_azslurm_panel_to_node_dashboards() {
  local extracted_dir="$1"
  local slurm_panel_path slurm_panel_uid slurm_panel_name dashboard_file dashboard_path temp_dashboard_path

  slurm_panel_path="$extracted_dir/$SLURM_BUTTONS_PANEL_REL_PATH"
  if [ ! -f "$slurm_panel_path" ]; then
    echo "AzSlurm button panel not found at $slurm_panel_path; skipping dashboard updates."
    return 0
  fi

  slurm_panel_uid=$(jq -r '.uid // empty' "$slurm_panel_path")
  slurm_panel_name=$(jq -r '.name // empty' "$slurm_panel_path")
  if [ -z "$slurm_panel_uid" ] || [ -z "$slurm_panel_name" ]; then
    echo "AzSlurm panel file is missing .uid or .name: $slurm_panel_path"
    return 1
  fi

  if ! import_library_panel "$slurm_panel_path"; then
    echo "Failed to import AzSlurm library panel from $slurm_panel_path"
    return 1
  fi

  for dashboard_file in "${TARGET_DASHBOARDS[@]}"; do
    dashboard_path="$THIS_DIR/dashboards/$dashboard_file"
    if [ ! -f "$dashboard_path" ]; then
      echo "Dashboard file not found: $dashboard_path"
      return 1
    fi

    temp_dashboard_path="$TEMP_DIR/${dashboard_file%.json}_with_azslurm.json"

    jq \
      --arg slurm_uid "$slurm_panel_uid" \
      --arg slurm_name "$slurm_panel_name" \
      --arg node_uid "$NODE_BUTTONS_UID" '
      .panels = (
        [
          .panels[]
          | if ((.libraryPanel.uid // "") == $node_uid) then
              .gridPos.x = 13 |
              .gridPos.w = 11 |
              .gridPos.y = 0
            elif ((.libraryPanel.uid // "") == $slurm_uid) then
              .gridPos.x = 0 |
              .gridPos.w = 13 |
              .gridPos.y = 0
            else
              .
            end
        ]
        + if ([.panels[]? | select((.libraryPanel.uid // "") == $slurm_uid)] | length) > 0 then
            []
          elif ([.panels[]? | select((.libraryPanel.uid // "") == $node_uid)] | length) > 0 then
            [{
              "gridPos": {
                "h": 3,
                "w": 13,
                "x": 0,
                "y": 0
              },
              "id": null,
              "libraryPanel": {
                "name": $slurm_name,
                "uid": $slurm_uid
              },
              "title": "",
              "type": "library-panel-ref"
            }]
          else
            []
          end
      )
    ' "$dashboard_path" > "$temp_dashboard_path"

    echo "Importing dashboard with AzSlurm buttons: $dashboard_file"
    az grafana dashboard import \
      --name "$GRAFANA_NAME" \
      --resource-group "$RESOURCE_GROUP_NAME" \
      --folder "$FOLDER_NAME" \
      --overwrite true \
      --definition "$temp_dashboard_path"
  done
}

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# Get the latest release tag of cyclecloud-slurm
LATEST_TAG=$(curl --fail --silent --show-error https://api.github.com/repos/Azure/cyclecloud-slurm/releases/latest | jq -r '.tag_name // empty')
if [ -z "$LATEST_TAG" ]; then
  echo "Could not determine latest cyclecloud-slurm release tag; skipping Slurm dashboards."
  exit 0
fi

TARBALL_PATH="$TEMP_DIR/cyclecloud-slurm.tar.gz"
EXTRACTED_DIR="$TEMP_DIR/cyclecloud-slurm-${LATEST_TAG}"
curl --fail --location --silent --show-error -o "$TARBALL_PATH" https://github.com/Azure/cyclecloud-slurm/archive/refs/tags/${LATEST_TAG}.tar.gz
tar -xzf "$TARBALL_PATH" -C "$TEMP_DIR"
if [ ! -d "$EXTRACTED_DIR/azure-slurm-exporter" ]; then
  echo "azure-slurm-exporter directory not found in release. Skipping."
else
  GRAFANA_ENDPOINT=$(az grafana show -n "$GRAFANA_NAME" -g "$RESOURCE_GROUP_NAME" --query properties.endpoint -o tsv | tr -d '\r\n')
  cd "$EXTRACTED_DIR/azure-slurm-exporter"
  chmod +x add_dashboards.sh
  ./add_dashboards.sh $RESOURCE_GROUP_NAME $GRAFANA_NAME

  GRAFANA_ENDPOINT=$(az grafana show -n "$GRAFANA_NAME" -g "$RESOURCE_GROUP_NAME" --query properties.endpoint -o tsv | tr -d '\r\n')
  if ! import_library_panel "$NODE_BUTTONS_PANEL_FILE"; then
    echo "Failed to restore the local node dashboard button panel"
    exit 1
  fi

  echo "Adding AzSlurm library panel to node dashboards..."
  if ! add_azslurm_panel_to_node_dashboards "$EXTRACTED_DIR"; then
    exit 1
  fi
fi
