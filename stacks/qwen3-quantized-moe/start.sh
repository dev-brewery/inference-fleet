#!/bin/sh
##############################################################################
# Docker Startup Script for Qwen3-Coder-Next on 2x Tesla P40
##############################################################################

MODEL="/models/Qwen3-Coder-Next-Q3_K_M.gguf"
# Use CTX_SIZE env var if set, otherwise default to 98304 (96K)
CTX=${CTX_SIZE:-98304}
THREADS=32
# Use BATCH_SIZE env var if set, otherwise default to 16384 (16K)
BATCH_SIZE=${BATCH_SIZE:-16384}
N_GPU_LAYERS=999
TENSOR_SPLIT="24,24"
SPLIT_MODE="row"

echo "[startup] Checking GPU availability..."

if ! command -v nvidia-smi > /dev/null 2>&1; then
    echo "[startup] WARNING: nvidia-smi not found in container"
else
    echo "[startup] GPU Configuration:"
    nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader | \
    while IFS=, read -r idx name mem_total mem_free; do
        echo "  GPU $idx: $name"
        echo "    Total VRAM: $mem_total"
        echo "    Free VRAM:  $mem_free"
    done
fi

echo "[startup] Model Architecture: Sparse MoE (80B total, 3B active per token)"
echo "[startup] Model: $MODEL"
echo "[startup] Context Size: $CTX"
echo "[startup] Batch Size: $BATCH_SIZE"
echo "[startup] N GPU Layers: $N_GPU_LAYERS (full offload)"
echo "[startup] Tensor Split: $TENSOR_SPLIT"
echo "[startup] Split Mode: $SPLIT_MODE"

echo "[startup] CRITICAL: Forcing MMQ kernels for Pascal GPUs..."
export GGML_CUDA_FORCE_MMQ=1

echo "[startup] Starting llama-server with Qwen3-Coder-Next..."

exec /app/llama-server \
  -m "$MODEL" \
  -c "$CTX" \
  --host 0.0.0.0 \
  --port 8080 \
  --threads "$THREADS" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size 512 \
  --context-shift \
  -ngl "$N_GPU_LAYERS" \
  -sm "$SPLIT_MODE" \
  -ts "$TENSOR_SPLIT" \
  --mlock \
  --metrics
