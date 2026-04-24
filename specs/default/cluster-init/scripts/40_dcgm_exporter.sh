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

# Remove any containers matching the dcgm-exporter image that do not have the
# expected name. This cleans up unnamed containers left by older versions of
# this script and containers whose name no longer matches the current config.
cleanup_legacy_dcgm_containers() {
    set +e
    local legacy
    legacy=$(docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' \
        | grep -i 'dcgm-exporter' \
        | grep -v " ${DCGM_CONTAINER_NAME} " \
        | awk '{print $1}')
    if [ -n "$legacy" ]; then
        echo "Removing legacy/unnamed DCGM containers: $legacy"
        docker rm -f $legacy
    fi
    set -e
}

# Ensure the expected DCGM exporter container is running.
# Strategy:
#   1. If a correctly-named container is already running with the right image, done.
#   2. If a container exists (stopped, wrong image, etc.), remove it and recreate.
#      A stopped container with --restart=always signals a real problem, so we
#      start fresh rather than blindly restarting stale state.
#   3. Otherwise, create a new container.
install_dcgm_exporter() {
    cleanup_legacy_dcgm_containers

    # Clean up orphaned containers in "Created" state from prior failed attempts
    set +e
    local orphaned
    orphaned=$(docker ps -a -q --filter "ancestor=${DCGM_IMAGE}" --filter "status=created")
    if [ -n "$orphaned" ]; then
        echo "Removing orphaned DCGM containers: $orphaned"
        docker rm $orphaned
    fi
    set -e

    # Check if the named container is already running with the correct image
    set +e
    local running_image
    running_image=$(docker inspect --format '{{.Config.Image}}' "$DCGM_CONTAINER_NAME" 2>/dev/null)
    local running
    running=$(docker ps -q --filter "name=^/${DCGM_CONTAINER_NAME}$" --filter "status=running")
    set -e

    if [ -n "$running" ] && [ "$running_image" = "$DCGM_IMAGE" ]; then
        echo "DCGM exporter container ${DCGM_CONTAINER_NAME} is already running with correct image, skipping."
        return 0
    fi

    # If a container exists but is not running or has wrong image, remove it.
    # With --restart=always, a stopped container likely hit a persistent error.
    # Removing and recreating gives us a clean slate with current config.
    set +e
    local existing
    existing=$(docker ps -a -q --filter "name=^/${DCGM_CONTAINER_NAME}$")
    set -e

    if [ -n "$existing" ]; then
        echo "Removing existing DCGM container (stopped or wrong image). Will recreate."
        docker rm -f "$DCGM_CONTAINER_NAME"
    fi

    # Start a new container
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

    yq eval-all '. as $item ireduce ({}; . *+ $item)' "$PROM_CONFIG" "$SPEC_FILE_ROOT/dcgm_exporter.yml" > tmp.yml
    mv -vf tmp.yml "$PROM_CONFIG"

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" "$PROM_CONFIG"

    systemctl restart prometheus
}

# Install DCGM exporter container - failure must not prevent scrape config
set +e
if ! install_dcgm_exporter; then
    echo "WARNING: install_dcgm_exporter failed, continuing to configure Prometheus scrape target."
fi
set -e

install_yq
add_scraper
