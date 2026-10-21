#!/bin/bash

# Configuration variables
MODEL="facebook/opt-125m"
CONTAINER_NAME="vllm-cpu-startup-test"
PORT=8000

# 1. Ensure any stale test containers from previous runs are cleaned up
podman rm -f $CONTAINER_NAME >/dev/null 2>&1

echo "📦 Pulling/verifying Docker container image..."
# Pre-warm Docker cache so network download time doesn't skew your startup benchmark
#docker inspect vllm/vllm-openapi:latest >/dev/null 2>&1 || docker pull vllm/vllm-openapi:latest
podman inspect vllm/vllm-cpu:latest >/dev/null 2>&1 || podman pull vllm/vllm-cpu:latest

echo "⏱️ Starting timer and launching containerized vLLM engine..."
# Capture high-precision start timestamp (nanoseconds)
start_time=$(date +%s.%N)

# 2. Spin up vLLM-cpu container
# REMOVED: '--gpus all \'
# Consider adding 'OMP_NUM_THREADS'
podman run -d \
    --name $CONTAINER_NAME \
    -p $PORT:$PORT \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    --ipc=host \
    vllm/vllm-cpu:latest \
    --model "$MODEL" > /dev/null

# 3. Poll the internal /health API route until it yields HTTP 200 OK
echo "🔄 Waiting for API health checkpoint to respond..."
while true; do
    # Perform a quick curl request targeting the local container port
    status_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/health || echo "000")
    
    if [ "$status_code" -eq 200 ]; then
        break
    fi
    # Wait briefly before querying again to avoid flooding logs
#    sleep 0.1
    sleep 1
done

# 4. Capture high-precision end timestamp
end_time=$(date +%s.%N)

# 5. Compute the delta using bc
startup_time=$(echo "$end_time - $start_time" | bc)

echo "--------------------------------------------------------"
echo "🚀 vLLM Container Status: ONLINE & HEALTHY"
echo "⏱️ Total Containerized Startup Time: ${startup_time} seconds"
echo "--------------------------------------------------------"

# 6. Teardown background test container
echo "🧹 Cleaning up vllm-cpu benchmark container..."
podman rm -f $CONTAINER_NAME >/dev/null 2>&1
echo "✅ Finished."
