#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -eo pipefail

# --- CONFIGURATION ---
MODEL_NAME="facebook/opt-125m"  # Replace with your target model
CONTAINER_NAME="vllm-cpu-benchmark"
IMAGE_NAME="docker.io/vllm/vllm-openai-cpu:v0.31.0"
##IMAGE_NAME="vllm/vllm-openai:cpu"
PORT=8000

# Cleanup handler to ensure podman container is stopped if script is interrupted
cleanup() {
    echo -e "\n[~] Cleaning up..."
    if podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo "[*] Stopping and removing container '${CONTAINER_NAME}'..."
        podman rm -f "${CONTAINER_NAME}" > /dev/null 2>&1
    fi
}
trap cleanup EXIT

# --- INITIALIZATION ---
echo "[*] Pulling image if not present: ${IMAGE_NAME}..."
if podman pull "${IMAGE_NAME}" > /dev/null 2>&1; then
    echo "Pull succeeded"
else
    echo "Pull failed"
    cleanup
fi    

echo "[*] Starting vLLM CPU Container..."
START_TIME=$(date +%s.%N)

# Run the podman container in the background
podman run -d \
    --name "${CONTAINER_NAME}" \
    -v ~/.cache/huggingface:/root/.cache/huggingface:Z \
    --ipc=host \
    -p ${PORT}:${PORT} \
    -e OMP_NUM_THREADS=$(nproc) \
    "${IMAGE_NAME}" \
    --model "${MODEL_NAME}" \
    > /dev/null 
if [ $? -eq 0 ]; then
    echo "[*] Container process spawned. Polling for engine readiness..."
else
    echo "Podman run command failed"
    cleanup
fi

HEALTH_TIME=""
READY_TIME=""
TIMEOUT=600       # 10 minutes timeout
ELAPSED=0

# --- POLLING LOOP ---
while true; do
    CURRENT_TIME=$(date +%s.%N)
    ELAPSED=$(echo "$CURRENT_TIME - $START_TIME" | bc)
    
    # Check if timeout exceeded
    if (( $(echo "$ELAPSED > $TIMEOUT" | bc -l) )); then
        echo "[!] Timeout reached without full engine readiness."
        exit 1
    fi

    # 1. Measure Basic Server Health (/health)
    if [ -z "$HEALTH_TIME" ]; then
        if curl -s -f "http://localhost:${PORT}/health" > /dev/null; then
            HEALTH_TIME=$CURRENT_TIME
            HEALTH_DELTA=$(echo "$HEALTH_TIME - $START_TIME" | bc)
            echo "[+] HTTP Server Alive (/health) in: $(printf "%.2f" "$HEALTH_DELTA") seconds"
        fi
    fi

    # 2. Measure Inference Readiness (/v1/models)
    if [ -z "$READY_TIME" ]; then
        # vLLM marks this endpoint live only when the model is loaded, KV cache is allocated, and loops are active
        if curl -s -f "http://localhost:${PORT}/v1/models" > /dev/null; then
            READY_TIME=$CURRENT_TIME
            READY_DELTA=$(echo "$READY_TIME - $START_TIME" | bc)
            echo "[+] Engine Inference Ready (/v1/models) in: $(printf "%.2f" "$READY_DELTA") seconds"
            break
        fi
    fi

    # Slight pause to prevent hammering the local network stack
    sleep 0.2
done

# --- RUN vllm bench serve AGAINST EXISTING vLLM server
echo "[*] Starting vLLM BENCH SERVE Container..."
START_BENCH_SERVE=$(date +%s.%N)
podman run --rm -it \
    --name vllm-bench-serve \
    --network host \
    --entrypoint vllm \
    "${IMAGE_NAME}" \
    bench serve \
        --percentiles 95 \
        --backend vllm \
        --base-url http://127.0.0.1:8000 \
        --model "${MODEL_NAME}" \
        --dataset-name random \
        --num-prompts 100 \
        --max-concurrency 5
END_BENCH_SERVE=$(date +%s.%N)

# --- FINAL REPORT ---
TOTAL_HEALTH=$(echo "$HEALTH_TIME - $START_TIME" | bc)
TOTAL_READY=$(echo "$READY_TIME - $START_TIME" | bc)
MODEL_LOADING_LAG=$(echo "$READY_TIME - $HEALTH_TIME" | bc)
TOTAL_BENCH_SERVE=$(echo "$END_BENCH_SERVE - $START_BENCH_SERVE" | bc)

echo -e "\n=============================================="
echo -e "         vLLM CPU STARTUP BENCHMARK"
echo -e "=============================================="
echo -e "Image Name:          ${IMAGE_NAME}"
echo -e "Model Name:          ${MODEL_NAME}"
echo -e "HTTP Base Server:    $(printf "%.2f" "$TOTAL_HEALTH") seconds"
echo -e "Inference Ready:     $(printf "%.2f" "$TOTAL_READY") seconds"
echo -e "----------------------------------------------"
echo -e "Model Loading & init overhead: $(printf "%.2f" "$MODEL_LOADING_LAG") seconds"
echo -e "BENCH SERVE Runtime:     $(printf "%.2f" "$TOTAL_BENCH_SERVE") seconds"
echo -e "=============================================="
