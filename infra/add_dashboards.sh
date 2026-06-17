#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Parse arguments
SLURM_FLAG=""
RESOURCE_GROUP_NAME=""
GRAFANA_NAME=""

for arg in "$@"; do
  case $arg in
    --slurm)
      SLURM_FLAG=true
      ;;
    -*)
      echo "Unknown option: $arg"
      echo "Usage: $0 <resource-group-name> <grafana-name> [--slurm]"
      exit 1
      ;;
    *)
      if [ -z "$RESOURCE_GROUP_NAME" ]; then
        RESOURCE_GROUP_NAME=$arg
      elif [ -z "$GRAFANA_NAME" ]; then
        GRAFANA_NAME=$arg
      else
        echo "Unexpected argument: $arg"
        echo "Usage: $0 <resource-group-name> <grafana-name> [--slurm]"
        exit 1
      fi
      ;;
  esac
done

if [ -z "$GRAFANA_NAME" ]; then
  echo "Usage: $0 <resource-group-name> <grafana-name> [--slurm]"
  exit 1
fi
if [ -z "$RESOURCE_GROUP_NAME" ]; then
  echo "Usage: $0 <resource-group-name> <grafana-name> [--slurm]"
  exit 1
fi

FOLDER_NAME="Azure CycleCloud"
DASHBOARD_FOLDER=$THIS_DIR/dashboards
LIBRARY_PANEL_FOLDER=$DASHBOARD_FOLDER/library-panels
# Audience used to request a token for the Azure Managed Grafana REST API
GRAFANA_AAD_RESOURCE="ce34e7e5-485f-4d76-964f-b3d2b16d1e4f"
# Create Grafana dashboards folders
az grafana folder show -n $GRAFANA_NAME -g $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "$FOLDER_NAME folder does not exist. Creating it."
  az grafana folder create --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --title "$FOLDER_NAME"
fi

# Library panels (must exist before importing dashboards that reference them).
# az grafana has no library-panel command, so call the Grafana REST API directly.
if [ -d "$LIBRARY_PANEL_FOLDER" ] && ls "$LIBRARY_PANEL_FOLDER"/*.json > /dev/null 2>&1; then
  GRAFANA_ENDPOINT=$(az grafana show -n $GRAFANA_NAME -g $RESOURCE_GROUP_NAME --query properties.endpoint -o tsv | tr -d '\r\n')
  GRAFANA_TOKEN=$(az account get-access-token --resource $GRAFANA_AAD_RESOURCE --query accessToken -o tsv | tr -d '\r\n')
  for panel_file in "$LIBRARY_PANEL_FOLDER"/*.json; do
    panel_uid=$(jq -r '.uid' "$panel_file")
    panel_name=$(jq -r '.name' "$panel_file")
    echo "Upserting library panel: $panel_name ($panel_uid)"
    existing_version=$(curl -s --http1.1 -H "Authorization: Bearer $GRAFANA_TOKEN" \
      "$GRAFANA_ENDPOINT/api/library-elements/$panel_uid" | jq -r '.result.version // empty')
    if [ -z "$existing_version" ]; then
      # Create new library panel
      curl -s -f --http1.1 -X POST \
        -H "Authorization: Bearer $GRAFANA_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$panel_file" \
        "$GRAFANA_ENDPOINT/api/library-elements" > /dev/null \
        && echo "  created" || echo "  failed to create $panel_uid"
    else
      # Update existing library panel (PATCH requires the current version)
      payload=$(jq --argjson v "$existing_version" '{name, kind, model, version: $v}' "$panel_file")
      curl -s -f --http1.1 -X PATCH \
        -H "Authorization: Bearer $GRAFANA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$GRAFANA_ENDPOINT/api/library-elements/$panel_uid" > /dev/null \
        && echo "  updated" || echo "  failed to update $panel_uid"
    fi
  done
fi


# Single node dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/node.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/infiniband.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/node_level.json

# Combined view dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/combined_view.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/combined_view_without_gpu_profiling.json

# GPU dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/gpu_device.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/gpu_profiling.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/gpu_level.json

# Cluster View dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/cluster_view_timeseries.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/cluster_view_with_heatmap.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/cluster_nodearray_overview.json

# Slurm dashboards
if [ "$SLURM_FLAG" = true ]; then
  echo "Adding Slurm dashboards..."
  $THIS_DIR/add_slurm_dashboards.sh $RESOURCE_GROUP_NAME $GRAFANA_NAME
fi

