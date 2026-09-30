#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CONFIGURATION ---
CONTAINER_NAME="pcp-service"
REMOTE_CONF_PATH="/tmp/custom_pmlogger.conf"
# DYNAMIC FIX: Automatically detects the correct directory name using your host's literal hostname
HOST_FQDN=$(hostname)
##REMOTE_ARCHIVE_PATH="/var/log/pcp/pmlogger/${HOST_FQDN}/benchmark_run"
REMOTE_ARCHIVE_PATH="/var/log/pcp/pmlogger/vllm_bench_run"

# Path to your external configuration file on the host
EXTERNAL_HOST_CONF="./pmlogger.conf"

# Generate a uniquely sortable timestamped folder name for the host
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOST_OUTPUT_DIR="./host_pcp_archives/vllm_bench_run_${TIMESTAMP}"

# --- STEP 1: VERIFY ENVIRONMENT & CONFIG ---
echo "=== [1/6] Validating environment and configuration file ==="
if [ ! -f "$EXTERNAL_HOST_CONF" ]; then
    echo "ERROR: External configuration file not found at: $EXTERNAL_HOST_CONF"
    echo "Please create a local rule file named '$EXTERNAL_HOST_CONF' on your host."
    exit 1
fi

if [ ! "$(podman ps -q -f name=^${CONTAINER_NAME}$ -f status=running)" ]; then
    echo "ERROR: Podman container '${CONTAINER_NAME}' is not running!"
    exit 1
fi
echo "Environment and config file ($EXTERNAL_HOST_CONF) validated successfully."

# --- STEP 2: STREAM EXTERNAL CONFIG TO CONTAINER ---
echo "=== [2/6] Streaming external configuration into container ==="
podman exec -i "${CONTAINER_NAME}" sh -c "cat > ${REMOTE_CONF_PATH}" < "$EXTERNAL_HOST_CONF"
echo "Configuration safely synchronized to container path: ${REMOTE_CONF_PATH}"

# --- STEP 3: START LOGGER IN DETACHED MODE ---
echo "=== [3/6] Launching background pmlogger instance ==="
podman exec -d "${CONTAINER_NAME}" /usr/libexec/pcp/bin/pmlogger \
    -t 1s \
    -c "${REMOTE_CONF_PATH}" \
    "${REMOTE_ARCHIVE_PATH}"
echo "Logging engine initialized using external rules."

# --- STEP 4: VLLM BENCH run
echo "=== [4/6] Running VLLM BENCH Workload ==="
podman run --rm -it --entrypoint vllm --shm-size=16g \
    public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.21.0 \
    bench throughput --model Qwen/Qwen2.5-1.5B-Instruct \
    --dataset-name random --random-input-len 256 \
    --random-output-len 64 --num-prompts 20 --load-format dummy

echo -e "\nVLLM BENCH Workload finished!"

# --- STEP 5: GRACEFULLY TERMINATE PMLOGGER ---
echo "=== [5/6] Sending SIGINT to flush performance buffers ==="
if podman exec "${CONTAINER_NAME}" pgrep pmlogger > /dev/null; then
    podman exec "${CONTAINER_NAME}" pkill -SIGINT pmlogger
    echo "Waiting for file system sync..."
    while podman exec "${CONTAINER_NAME}" pgrep pmlogger > /dev/null; do
        sleep 0.5
    done
    echo "Logging engine terminated cleanly."
else
    echo "WARNING: pmlogger was not running."
fi

# --- STEP 6: EXTRACT PCP ARCHIVE RECURSIVELY ---
echo "=== [6/6] Extracting compiled archives to timestamped directory ==="
mkdir -p "${HOST_OUTPUT_DIR}"
# Updated to target the parent directory containing your new archive files
podman cp "${CONTAINER_NAME}:${REMOTE_ARCHIVE_PATH}.0" "${HOST_OUTPUT_DIR}/" 2>/dev/null || true
podman cp "${CONTAINER_NAME}:${REMOTE_ARCHIVE_PATH}.index" "${HOST_OUTPUT_DIR}/" 2>/dev/null || true
podman cp "${CONTAINER_NAME}:${REMOTE_ARCHIVE_PATH}.meta" "${HOST_OUTPUT_DIR}/" 2>/dev/null || true

echo "SUCCESS: Benchmark archive extracted to: ${HOST_OUTPUT_DIR}"

# --- STEP 7: VALIDATION VIA PMDUMPLOG ---
echo "=== [VALIDATION] Verifying Archive Content Integrity ==="
LOCAL_ARCHIVE_BASE="${HOST_OUTPUT_DIR}/benchmark_run"
if [ -f "${LOCAL_ARCHIVE_BASE}.index" ] || [ -f "${LOCAL_ARCHIVE_BASE}.0" ]; then
    echo "--------------------------------------------------------"
    if command -v pmdumplog &> /dev/null; then
        pmdumplog -l "${LOCAL_ARCHIVE_BASE}"
    else
        echo "Local host 'pmdumplog' not found. Falling back to internal container validation..."
        podman exec "${CONTAINER_NAME}" pmdumplog -l "${REMOTE_ARCHIVE_PATH}"
    fi
    echo "--------------------------------------------------------"
    echo "Validation check complete."
else
    echo "ERROR: Validation failed. Required archive binary files were not found!"
    exit 1
fi
