#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
source "$SPEC_FILE_ROOT/common.sh" 

NODE_EXPORTER_VERSION=1.9.1
NODE_EXPORTER_PACKAGE=node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
if is_arm64; then
    NODE_EXPORTER_PACKAGE=node_exporter-$NODE_EXPORTER_VERSION.linux-arm64.tar.gz
fi
PROM_CONFIG=/opt/prometheus/prometheus.yml


if ! is_monitoring_enabled; then
    exit 0
fi
function run_container_exporter() {
    # Run Node Exporter in a container
    docker run -d --name node_exporter --restart unless-stopped \
        -p 9100:9100 \
        -v "/:/host:ro,rslave" \
        --pid=host \
        --net=host \
        --cap-add SYS_ADMIN \
        --cap-add SYS_PTRACE \
        quay.io/prometheus/node-exporter:latest \
            --path.rootfs=/host \
            --collector.mountstats \
            --collector.cpu.info \
            --no-collector.arp \
            --no-collector.bcache \
            --no-collector.bonding \
            --no-collector.btrfs \
            --no-collector.conntrack \
            --no-collector.cpufreq \
            --no-collector.dmi \
            --no-collector.edac \
            --no-collector.entropy \
            --no-collector.fibrechannel \
            --no-collector.filefd \
            --no-collector.hwmon \
            --no-collector.ipvs \
            --no-collector.mdadm \
            --no-collector.netclass \
            --no-collector.netstat \
            --no-collector.nfs \
            --no-collector.nfsd \
            --no-collector.nvme \
            --no-collector.os \
            --no-collector.powersupplyclass \
            --no-collector.pressure \
            --no-collector.rapl \
            --no-collector.schedstat \
            --no-collector.selinux \
            --no-collector.sockstat \
            --no-collector.softnet \
            --no-collector.tapestats \
            --no-collector.textfile \
            --no-collector.thermal_zone \
            --no-collector.timex \
            --no-collector.udp_queues \
            --no-collector.watchdog \
            --no-collector.xfs \
            --no-collector.zfs
}

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
#install_node_exporter
run_container_exporter
install_yq
add_scraper
