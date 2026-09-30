#!/bin/bash
set -e

# --- CONFIGURATION ---
# Correct public registry destination for upstream PCP
IMAGE_NAME="ghcr.io/performancecopilot/pcp:latest"
CONTAINER_NAME="pcp-service"
WAS_HOST_PMCD_RUNNING=false

# --- STEP 0: CLEANUP & RESTORATION TRAP ---
restore_host_environment() {
    echo "=================================================="
    echo "Restoring host environment and cleaning up PCP..."
    echo "=================================================="

    local container_name="pcp-service"

    # 1. Check if the container is running or exists
    if podman container exists "$container_name"; then

        # Check if it is currently running
        if [ "$(podman inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" = "true" ]; then
            echo "Stopping running container: $container_name..."
            # Using a 10-second timeout to allow pmlogger/pmcd to flush logs and exit cleanly
            podman stop -t 10 "$container_name"
        fi

        # 2. Remove the container to clean up its filesystem layer
        echo "Removing container: $container_name..."
        podman rm "$container_name"
    else
        echo "Container $container_name does not exist. Skipping stop/remove."
    fi

    # 3. Optional: Clean up dangling system resources if necessary
    # podman volume rm pcp_data_volume 2>/dev/null || true

    # 4. Restore PMCD on Host
    if [ "$WAS_HOST_PMCD_RUNNING" = true ]; then
        echo "Restarting host native pmcd service..."
        sudo systemctl start pmcd || echo "Warning: Failed to restart host pmcd."
    fi
    echo "Host environment restoration complete."
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

echo "Running CGROUP validation diagnostic check..."
if pminfo -h localhost:44321 -t cgroup; then
    echo "========================================================"
    echo "SUCCESS: Official '${CONTAINER_NAME}' container is running!"
    echo "========================================================"
else
    echo "ERROR: Validation check failed. Container runtime logs:"
    podman logs "$CONTAINER_NAME"
    exit 1
fi

# Install DENKI agent
echo "Installing DENKI PMDA to enable RAPL metrics..."
podman exec -u root -w /var/lib/pcp/pmdas/denki -it "$CONTAINER_NAME" ./Install

echo "Running DENKI validation diagnostic check..."
if pminfo -h localhost:44321 -t denki; then
    echo "========================================================"
    echo "SUCCESS: Official '${CONTAINER_NAME}' container is running!"
    echo "========================================================"
else
    echo "ERROR: Validation check failed. Container runtime logs:"
    podman logs "$CONTAINER_NAME"
    exit 1
fi

# Stop the primary PMLOGGER
podman exec -u root "$CONTAINER_NAME" systemctl stop pmlogger

# Announce completion
echo "PCP layer is up. Press [Ctrl+C] to exit and restore host settings."
while true; do
    sleep 1
done
