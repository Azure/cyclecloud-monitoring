#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml

source "$SPEC_FILE_ROOT/common.sh"

SLURM_EXPORTER_PORT=9080

SLURM_EXPORTER_REPO="https://github.com/SlinkyProject/slurm-exporter.git"
SLURM_EXPORTER_COMMIT="478da458dd9f59ecc464c1b5e90a1a8ebc1a10fb"
SLURM_EXPORTER_IMAGE_NAME="slinky.slurm.net/slurm-exporter:0.3.0"

if ! is_monitoring_enabled; then
    exit 0
fi

# Only install Slurm Exporter on Scheduler
if ! is_scheduler ; then
    echo "Do not install the Slurm Exporter since this is not the scheduler." 
    exit 0
fi

echo "Installing Slurm Exporter..."

install_prerequisites() {
    # This should ALL be installed and configured by cyclecloud-slurm project in the future

    # See: https://github.com/benmcollins/libjwt
    if command -v apt-get &> /dev/null; then
        apt-get install -y git libjansson-dev libjwt-dev binutils golang-go
    else 
        dnf install -y libjansson-devel libjwt-dev binutils golang-go
    fi

    # Configure JWT and slurmrestd

    # Create a local key
    mkdir -pv /var/spool/slurm/statesave
    dd if=/dev/random of=/var/spool/slurm/statesave/jwt_hs256.key bs=32 count=1
    chown slurm:slurm /var/spool/slurm/statesave/jwt_hs256.key
    chmod 0600 /var/spool/slurm/statesave/jwt_hs256.key
    chown slurm:slurm /var/spool/slurm/statesave
    chmod 0755 /var/spool/slurm/statesave

    # Add to JWT Auth to the slurm.conf
    # Check if the line already exists
    lines_to_insert="AuthAltTypes=auth/jwt\nAuthAltParameters=jwt_key=/var/spool/slurm/statesave/jwt_hs256.key\n"
    if ! grep -q "AuthAltTypes=auth/jwt" /etc/slurm/slurm.conf; then
        sed -i --follow-symlinks '/^Include azure.conf/a '"$lines_to_insert"'' /etc/slurm/slurm.conf        
    fi
    if ! grep -q "AuthAltTypes=auth/jwt" /etc/slurm/slurmdbd.conf; then
        sed -i --follow-symlinks '/^# Authentication info/a '"$lines_to_insert"'' /etc/slurm/slurmdbd.conf        
    fi

    # Create an unprivileged user for slurmrestd
    if id "slurmrestd" &>/dev/null; then
        echo "User slurmrestd exists"
    else
        useradd -M -r -s /usr/sbin/nologin -U slurmrestd
    fi    

    # Add user to the docker group
    if getent group docker | grep -qw slurmrestd; then
        echo "User slurmrestd belongs to group docker"
    else
        usermod -aG docker slurmrestd
    fi
    
    newgrp docker

    # Create a socket for the slurmrestd
    mkdir -pv /var/spool/slurmrestd
    touch /var/spool/slurmrestd/slurmrestd.socket
    chown -R slurmrestd:slurmrestd /var/spool/slurmrestd

    # Configure the slurmrestd:
     cat <<EOF > /etc/default/slurmrestd
SLURMRESTD_OPTIONS="-u slurmrestd -g slurmrestd"
SLURMRESTD_LISTEN=:6820,unix:/var/spool/slurmrestd/slurmrestd.socket
EOF
    chmod 644 /etc/default/slurmrestd

    # Restart the slurmctld, slurmdbd, slurmrestd:
    systemctl stop slurmctld.service
    systemctl start slurmctld.service
    systemctl status slurmctld.service
    systemctl stop slurmdbd.service
    systemctl start slurmdbd.service
    systemctl status slurmdbd.service
    systemctl stop slurmrestd.service
    systemctl start slurmrestd.service
    systemctl status slurmrestd.service
}


install_slurm_exporter() {

    # Build the exporter
    pushd /tmp
    rm -rf slurm-exporter
    git clone ${SLURM_EXPORTER_REPO}
    cd slurm-exporter
    
    # Pin the build to specific commit
    git checkout ${SLURM_EXPORTER_COMMIT}

    # Equivalent to:  docker build . -t slinky.slurm.net/slurm-exporter:0.3.0
    # "all" requires helm
    make docker-bake
    popd

    # Run Slurm Exporter in a container
    unset SLURM_JWT
    export $(scontrol token username="slurmrestd" lifespan=infinite)
    # Check if the token is set
    if [ -z "$SLURM_JWT" ]; then
        echo "Failed to get SLURM_JWT token - restarting slurm"
        # Restart slurmctld
        /opt/cycle/jetpack/system/bootstrap/azure-slurm-install/start-services.sh scheduler

        unset SLURM_JWT
        export $(scontrol token username="slurmrestd" lifespan=infinite)
        if [ -z "$SLURM_JWT" ]; then
            echo "Failed to get SLURM_JWT token after restarting slurm"
            exit 1
        fi
    fi

    # Check if the container is already running, and if so, stop it
    if [ "$(docker ps -q -f ancestor=$SLURM_EXPORTER_IMAGE_NAME)" ]; then
        echo "Slurm Exporter is already running, stopping it..."
        docker stop $(docker ps -q -f ancestor=$SLURM_EXPORTER_IMAGE_NAME)
    fi

    docker run -v /var:/var -e SLURM_JWT=${SLURM_JWT} -d --rm -p ${SLURM_EXPORTER_PORT}:8080 --add-host=host.docker.internal:host-gateway \
            $SLURM_EXPORTER_IMAGE_NAME -server http://host.docker.internal:6820 -per-user-metrics true -metrics-bind-address ":${SLURM_EXPORTER_PORT}"
    
    # Check if the container is running
    if [ "$(docker ps -q -f ancestor=$SLURM_EXPORTER_IMAGE_NAME)" ]; then
        echo "Slurm Exporter is running"
    else
        echo "Slurm Exporter is not running"
        exit 1
    fi

    # Check if metrics are available
    if curl -s http://localhost:${SLURM_EXPORTER_PORT}/metrics | grep -q "slurm_node_total"; then
        echo "Slurm Exporter metrics are available"
    else
        echo "Slurm Exporter metrics are not available"
        # HACK: For now, simply abort if Slurm exporter fails
        # TODO: This should be an error and fail converge
        exit 0
    fi
}

function add_scraper() {
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/slurm_exporter.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}

if is_scheduler ; then
    install_prerequisites
    install_slurm_exporter
    install_yq
    add_scraper
fi