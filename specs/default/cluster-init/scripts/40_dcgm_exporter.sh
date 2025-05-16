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
    CUDA_VERSION=$(nvidia-smi | sed -E -n 's/.*CUDA Version: ([0-9]+)[.].*/\1/p')
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --install-recommends datacenter-gpu-manager-4-cuda${CUDA_VERSION}

    systemctl daemon-reload
    systemctl restart nvidia-dcgm.service
    
    # Run DCGM Exporter in a container
    docker run -v $SPEC_FILE_ROOT/custom_dcgm_counters.csv:/etc/dcgm-exporter/custom-counters.csv \
            -d --gpus all --cap-add SYS_ADMIN --rm -p 9400:9400 \
            nvcr.io/nvidia/k8s/dcgm-exporter:4.2.0-4.1.0-ubuntu22.04 -f /etc/dcgm-exporter/custom-counters.csv
}

function add_scraper() {
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