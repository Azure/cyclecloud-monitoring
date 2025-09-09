#!/bin/bash
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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
DASHBOARD_FOLDER=$THIS_DIR/dashboards
# Create Grafana dashboards folders
az grafana folder show -n $GRAFANA_NAME -g $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "$FOLDER_NAME folder does not exist. Creating it."
  az grafana folder create --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --title "$FOLDER_NAME"
fi


# Single node dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/node.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/infiniband.json

# Combined view dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/combined_view.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/combined_view_without_gpu_profiling.json

# GPU dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/gpu_device.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/gpu_profiling.json

# Cluster View dashboards
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/cluster_view_timeseries.json
az grafana dashboard import --name $GRAFANA_NAME --resource-group $RESOURCE_GROUP_NAME --folder "$FOLDER_NAME" --overwrite true --definition $DASHBOARD_FOLDER/cluster_view_with_heatmap.json

