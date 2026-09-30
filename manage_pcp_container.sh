#!/bin/bash
set -e

# --- CONFIGURATION ---
# Correct public registry destination for upstream PCP
IMAGE_NAME="ghcr.io/performancecopilot/pcp:latest"
CONTAINER_NAME="pcp-service"
WAS_HOST_PMCD_RUNNING=false

# --- STEP 0: CLEANUP & RESTORATION TRAP ---
restore_host_environment() {
    echo -e "\n=== [CLEANUP] Restoring host environment ==="
    if [ "$WAS_HOST_PMCD_RUNNING" = true ]; then
        echo "Restarting host native pmcd service..."
        sudo systemctl start pmcd || echo "Warning: Failed to restart host pmcd."
    fi
}
trap restore_host_environment EXIT SIGINT SIGTERM

# --- STEP 1: MANAGE HOST PMCD CONFLICTS ---
echo "=== [1/3] Checking host for port 44321 conflicts ==="
if systemctl is-active --quiet pmcd; then
    echo "Stopping host pmcd temporarily..."
    sudo systemctl stop pmcd
    WAS_HOST_PMCD_RUNNING=true
fi

# --- STEP 2: CLEANUP STALE CONTAINERS ---
echo "=== [2/3] Cleaning Up Stale Environments ==="
if [ "$(podman ps -a -q -f name=^${CONTAINER_NAME}$)" ]; then
    echo "Removing old container instance..."
    podman rm -f "$CONTAINER_NAME"
fi

# --- STEP 3: LAUNCH OFFICIAL PREBUILT PCP SERVICE ---
echo "=== [3/3] Launching Official Prebuilt PCP Service ==="
podman run -d \
    --name "$CONTAINER_NAME" \
    --systemd always \
    --privileged \
    --ipc=host \
    --net=host \
    -v /sys:/sys:ro \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    "$IMAGE_NAME"

echo "Waiting for prebuilt pcp-service to initialize..."
sleep 5

echo "Running validation diagnostic check..."
if pminfo -h localhost:44321 -t cgroup; then
    echo "========================================================"
    echo "SUCCESS: Official '${CONTAINER_NAME}' container is running!"
    echo "========================================================"
else
    echo "ERROR: Validation check failed. Container runtime logs:"
    podman logs "$CONTAINER_NAME"
    exit 1
fi

echo "PCP layer is up. Press [Ctrl+C] to exit and restore host settings."
while true; do
    sleep 1
done
