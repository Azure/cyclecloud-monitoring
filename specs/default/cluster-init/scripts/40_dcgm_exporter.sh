#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml

source "$SPEC_FILE_ROOT/common.sh"

if ! is_monitoring_enabled; then
    exit 0
fi

# Check if nvidia-smi run successfully
if ! nvidia-smi -L > /dev/null 2>&1; then
    echo "nvidia-smi command failed. Do not install DCGM exporter."
    exit 0
fi

install_dcgm_exporter() {
    # Install NVIDIA DCGM
    # https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/getting-started.html
    CUDA_VERSION=$(nvidia-smi | sed -E -n 's/.*CUDA Version: ([0-9]+)[.].*/\1/p')
    . /etc/os-release
    case $ID in
        ubuntu)
            DEBIAN_FRONTEND=noninteractive apt-get install --yes --install-recommends datacenter-gpu-manager-4-cuda${CUDA_VERSION}
            ;;
        rocky|almalinux|centos)
            dnf install --assumeyes --setopt=install_weak_deps=True datacenter-gpu-manager-4-cuda${CUDA_VERSION} --allowerasing
            ;;
        *)
            echo "Unsupported OS: $ID"
            exit 1
            ;;
    esac

    systemctl daemon-reload
    systemctl restart nvidia-dcgm.service
    
    # Run DCGM Exporter in a container
    docker run -v $SPEC_FILE_ROOT/custom_dcgm_counters.csv:/etc/dcgm-exporter/custom-counters.csv \
            -d --gpus all --cap-add SYS_ADMIN --rm -p 9400:9400 \
            nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.3-ubuntu22.04 -f /etc/dcgm-exporter/custom-counters.csv
}

function add_scraper() {
    # If dcgm_exporter is already configured, do not add it again
    if grep -q "dcgm_exporter" $PROM_CONFIG; then
        echo "DCGM Exporter is already configured in Prometheus"
        return 0
    fi    
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/dcgm_exporter.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}

if is_compute ; then
    install_dcgm_exporter
    install_yq
    add_scraper
fi