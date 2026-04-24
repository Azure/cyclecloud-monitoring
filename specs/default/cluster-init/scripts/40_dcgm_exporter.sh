#!/bin/bash
# Installs yq, dcgm-exporter, and prom config
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.3-ubuntu22.04"
DCGM_CONTAINER_NAME="dcgm-exporter"
DCGM_PORT=9400

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
    # Check if a DCGM container is already running on the port
    if docker ps --format '{{.Ports}}' | grep -q "0.0.0.0:${DCGM_PORT}->"; then
        echo "DCGM exporter already running on port ${DCGM_PORT}, skipping docker run."
        # Clean up orphaned containers in "Created" state from prior failed attempts
        orphaned=$(docker ps -a -q --filter "ancestor=${DCGM_IMAGE}" --filter "status=created")
        if [ -n "$orphaned" ]; then
            echo "Removing orphaned DCGM containers: $orphaned"
            docker rm $orphaned || true
        fi
        return 0
    fi

    # Check if a named container exists but is stopped
    if docker ps -a -q --filter "name=^/${DCGM_CONTAINER_NAME}$" | grep -q .; then
        echo "DCGM exporter container exists but is stopped. Starting it."
        docker start "$DCGM_CONTAINER_NAME"
        return 0
    fi

    # No existing container - start a new one
    docker run --name "$DCGM_CONTAINER_NAME" \
            -v "$SPEC_FILE_ROOT/custom_dcgm_counters.csv:/etc/dcgm-exporter/custom-counters.csv" \
            -d --gpus all --cap-add SYS_ADMIN --restart always -p ${DCGM_PORT}:${DCGM_PORT} \
            "$DCGM_IMAGE" -f /etc/dcgm-exporter/custom-counters.csv
}

function add_scraper() {
    # If dcgm_exporter is already configured, do not add it again
    if grep -q "dcgm_exporter" "$PROM_CONFIG" 2>/dev/null; then
        echo "DCGM Exporter is already configured in Prometheus"
        return 0
    fi

    if [ ! -f "$PROM_CONFIG" ]; then
        echo "ERROR: $PROM_CONFIG does not exist. Cannot add dcgm_exporter scrape target."
        return 1
    fi

    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' "$PROM_CONFIG" "$SPEC_FILE_ROOT/dcgm_exporter.yml" > tmp.yml
    mv -vf tmp.yml "$PROM_CONFIG"

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" "$PROM_CONFIG"

    systemctl restart prometheus
}

# Install DCGM exporter container - failure must not prevent scrape config
if ! install_dcgm_exporter; then
    echo "WARNING: install_dcgm_exporter failed, continuing to configure Prometheus scrape target."
fi

install_yq
add_scraper
