#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$THIS_DIR/util.sh"

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

# Create Grafana dashboards folders
az grafana folder show -n $GRAFANA_NAME -g $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "$FOLDER_NAME folder does not exist. Creating it."
  az grafana folder create --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --title "$FOLDER_NAME"
fi

# Library panels (must exist before importing dashboards that reference them).
if [ -d "$LIBRARY_PANEL_FOLDER" ] && ls "$LIBRARY_PANEL_FOLDER"/*.json > /dev/null 2>&1; then
  GRAFANA_ENDPOINT=$(az grafana show -n $GRAFANA_NAME -g $RESOURCE_GROUP_NAME --query properties.endpoint -o tsv | tr -d '\r\n')
  for panel_file in "$LIBRARY_PANEL_FOLDER"/*.json; do
    import_library_panel "$panel_file"
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

