#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROMETHEUS_VERSION=3.3.0
PROM_CONFIG=/opt/prometheus/prometheus.yml

source "$SPEC_FILE_ROOT/common.sh" 

if ! is_monitoring_enabled; then
    exit 0
fi

get_subscription(){
    subscription_id=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/subscriptionId?api-version=2021-02-01&format=text")

    echo $subscription_id
}

# Build a cluster name from the resource group and cluster name
get_cluster_name(){
    resource_group_name=$(jetpack config azure.metadata.compute.resourceGroupName)
    cluster_name=$(jetpack config cyclecloud.cluster.name)

    echo "$resource_group_name/$cluster_name"
}

get_physical_host_name(){
    KVP_PATH='/opt/azurehpc/tools/kvp_client'
    if [ -f "$KVP_PATH" ]; then
        HOST_NAME=$("$KVP_PATH" 3 | grep -i 'PhysicalHostName;' | awk -F 'Value:'  '{print $2}');
    elif [ -f "/var/lib/hyperv/.kvp_pool_3" ]; then
        HOST_NAME=$(strings /var/lib/hyperv/.kvp_pool_3 | grep -A1 PhysicalHostName | head -n 2 | tail -1)
    else
        HOST_NAME=physical_host_name
    fi
    echo $HOST_NAME
}

function install_prometheus() {
    # If /opt/prometheus doen't exist, download and extract prometheus
    if [ ! -d /opt/prometheus ]; then
        cd /opt
        wget -q https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
        mkdir -pv prometheus
        tar xvf  prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz -C prometheus --strip-components=1
        chown -R root:root prometheus
        rm -fv prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
    fi

    # Install prometheus service
    cp -v $SPEC_FILE_ROOT/prometheus.service /etc/systemd/system/

    # copy the prometheus configuration file
    cp -v $SPEC_FILE_ROOT/prometheus.yml $PROM_CONFIG

    INGESTION_ENDPOINT=$(jetpack config monitoring.ingestion_endpoint)
    IDENTITY_CLIENT_ID=$(jetpack config monitoring.identity_client_id)
    INSTANCE_NAME=$(hostname)
    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG
    sed -i "s@ingestion_endpoint@$INGESTION_ENDPOINT@" $PROM_CONFIG
    sed -i "s/identity_client_id/$IDENTITY_CLIENT_ID/" $PROM_CONFIG

    sed -i -r "s/subscription_id/$SUBSCRIPTION_ID/" $PROM_CONFIG
    sed -i -r "s|cluster_name|$CLUSTER_NAME|" $PROM_CONFIG
    sed -i -r "s/physical_host_name/$PHYS_HOST_NAME/" $PROM_CONFIG


    # Enable and start prometheus service
    systemctl daemon-reload
    systemctl enable prometheus
    systemctl start prometheus
}

# Always install prometheus
PHYS_HOST_NAME=$(get_physical_host_name)
CLUSTER_NAME=$(get_cluster_name)
SUBSCRIPTION_ID=$(get_subscription)
install_prometheus
