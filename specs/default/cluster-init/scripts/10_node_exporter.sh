#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
source "$SPEC_FILE_ROOT/common.sh" 

NODE_EXPORTER_VERSION=1.10.2
NODE_EXPORTER_PACKAGE=node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
if is_arm64; then
    NODE_EXPORTER_PACKAGE=node_exporter-$NODE_EXPORTER_VERSION.linux-arm64.tar.gz
fi
PROM_CONFIG=/opt/prometheus/prometheus.yml


if ! is_monitoring_enabled; then
    exit 0
fi

function install_node_exporter() {
    # If /opt/node_exporter doen't exist, download and extract node_exporter
    if [ ! -d /opt/node_exporter ]; then
        cd /opt
        wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}
        mkdir -pv node_exporter 
        tar xvf ${NODE_EXPORTER_PACKAGE} -C node_exporter --strip-components=1
        chown root:root -R node_exporter
        rm -fv ${NODE_EXPORTER_PACKAGE}
    fi

    # Install node exporter service
    cp -v $SPEC_FILE_ROOT/node_exporter.service /etc/systemd/system/

    # Create node_exporter group and user
    if ! getent group node_exporter >/dev/null; then
        groupadd -r node_exporter
    fi

    # Create node_exporter user
    if ! id -u node_exporter >/dev/null 2>&1; then
        useradd -r -g node_exporter -s /sbin/nologin node_exporter
    fi

    # Install node exporter socket
    cp -v $SPEC_FILE_ROOT/node_exporter.socket /etc/systemd/system/

    # Create /etc/sysconfig directory
    mkdir -pv /etc/sysconfig

    # Copy node exporter configuration file
    cp -v $SPEC_FILE_ROOT/sysconfig.node_exporter /etc/sysconfig/node_exporter

    # Enable and start node exporter service
    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter
}

function add_scraper() {
    # If node_exporter is already configured, do not add it again
    if grep -q "node_exporter" $PROM_CONFIG; then
        echo "Node Exporter is already configured in Prometheus"
        return 0
    fi 
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/node_exporter.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}


# Always install node_exporter
install_node_exporter
#install_yq
#add_scraper
