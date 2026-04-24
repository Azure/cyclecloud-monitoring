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

# Docker helper functions
# - Check if a named container is running. Returns 0 if running, 1 otherwise.
is_container_running() {
    local name="$1"
    if docker ps -q --filter "name=^/${name}$" --filter "status=running" | grep -q .; then
        return 0
    fi
    return 1
}

# - Get the image of a named container. Prints empty string if container does not exist.
get_container_image() {
    local name="$1"
    docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true
}

#  -Remove containers matching a docker ps filter. No-op if none match.
remove_containers_by_filter() {
    local matches
    matches=$(docker ps -a -q "$@") || true
    if [ -n "$matches" ]; then
        echo "Removing containers: $matches"
        docker rm -f $matches
    fi
}

# Cleanup functions
# - Remove dcgm-exporter containers that do not have the expected name.
# - Cleans up unnamed containers left by older versions of this script and
#   containers whose name no longer matches the current config.
cleanup_legacy_containers() {
    local legacy
    legacy=$(docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' \
        | grep -i 'dcgm-exporter' \
        | grep -v " ${DCGM_CONTAINER_NAME} " \
        | awk '{print $1}') || true
    if [ -n "$legacy" ]; then
        echo "Removing legacy/unnamed DCGM containers: $legacy"
        docker rm -f $legacy
    fi
}

# Remove containers stuck in "Created" state from prior failed docker run attempts.
cleanup_orphaned_containers() {
    remove_containers_by_filter --filter "ancestor=${DCGM_IMAGE}" --filter "status=created"
}

# Main functions
# Ensure the expected DCGM exporter container is running.
# - Clean up legacy and orphaned containers.
# - If correctly-named container is running with the right image, done.
# - If a container exists (stopped, wrong image, etc.), remove it and recreate.
#   A stopped container with --restart=always signals a persistent error, so
#   we start fresh rather than blindly restarting stale state.
# - Otherwise, create a new container.
install_dcgm_exporter() {
    cleanup_legacy_containers
    cleanup_orphaned_containers

    local current_image
    current_image=$(get_container_image "$DCGM_CONTAINER_NAME")

    if is_container_running "$DCGM_CONTAINER_NAME" && [ "$current_image" = "$DCGM_IMAGE" ]; then
        echo "DCGM exporter container ${DCGM_CONTAINER_NAME} is already running with correct image, skipping."
        return 0
    fi

    # Remove stale container if one exists (wrong image, stopped, etc.)
    if [ -n "$current_image" ]; then
        echo "Removing existing DCGM container (stopped or wrong image). Will recreate."
        docker rm -f "$DCGM_CONTAINER_NAME"
    fi

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
if ! install_dcgm_exporter; then
    echo "WARNING: install_dcgm_exporter failed, continuing to configure Prometheus scrape target."
fi

install_yq
add_scraper
