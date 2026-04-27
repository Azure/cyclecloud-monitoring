#!/bin/bash
# Installs yq, dcgm-exporter, and prom config
set -ex
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.3-ubuntu22.04"
DCGM_CONTAINER_NAME="dcgm-exporter"
DCGM_PORT=$(/opt/cycle/jetpack/bin/jetpack config cyclecloud.monitoring.dcgm_exporter_port 9400)

source "$SPEC_FILE_ROOT/common.sh"

if ! is_monitoring_enabled; then
    exit 0
fi

# Check if nvidia-smi run successfully
if ! nvidia-smi -L > /dev/null 2>&1; then
    echo "nvidia-smi command failed. Do not install DCGM exporter."
    exit 0
fi

# Docker helpers
# - Check if a named container is running. Returns 0 if running, 1 otherwise.
function is_container_running() {
    local name="$1"
    if docker ps -q --filter "name=^/${name}$" --filter "status=running" | grep -q .; then
        return 0
    fi
    return 1
}

# - Get the image of a named container. Prints empty string if container does not exist.
function get_container_image() {
    local name="$1"
    docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true
}

# - Remove ALL containers matching the dcgm-exporter image
function cleanup_all_dcgm_containers() {
    local matches
    matches=$(docker ps -a --format '{{.ID}} {{.Image}}' \
        | grep -i 'dcgm-exporter' \
        | awk '{print $1}') || true
    if [ -n "$matches" ]; then
        echo "Removing all DCGM exporter containers: $matches"
        docker rm -f $matches
    fi
}

# Main functions
# Ensure the expected DCGM exporter container is running.
# If the correct container is already running, this is a no-op.
# Otherwise, remove everything dcgm-related and start fresh.
function install_dcgm_exporter() {
    if is_container_running "$DCGM_CONTAINER_NAME" \
        && [ "$(get_container_image "$DCGM_CONTAINER_NAME")" = "$DCGM_IMAGE" ]; then
        echo "DCGM exporter container ${DCGM_CONTAINER_NAME} is already running with correct image, skipping."
        return 0
    fi

    cleanup_all_dcgm_containers

    docker run --name "$DCGM_CONTAINER_NAME" \
            -v "$SPEC_FILE_ROOT/custom_dcgm_counters.csv:/etc/dcgm-exporter/custom-counters.csv" \
            -d --gpus all --cap-add SYS_ADMIN --restart always -p "${DCGM_PORT}:${DCGM_PORT}" \
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

    local tmpfile
    tmpfile=$(mktemp)
    yq eval-all '. as $item ireduce ({}; . *+ $item)' "$PROM_CONFIG" "$SPEC_FILE_ROOT/dcgm_exporter.yml" > "$tmpfile"
    mv -vf "$tmpfile" "$PROM_CONFIG"

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
