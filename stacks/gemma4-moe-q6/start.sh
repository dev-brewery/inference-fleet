#!/bin/sh
##############################################################################
# Docker Startup Script for Gemma 4 26B-A4B (MoE) UD-Q6_K on 2x Tesla P40
#
# Backend: upstream ggml-org/llama.cpp (gemma4-server-local image)
#   NOT ik_llama.cpp — see gemma4-moe-q8/build.sh for rationale.
##############################################################################

MODEL="/models/gemma-4-26b-a4b-it/gemma-4-26B-A4B-it-UD-Q6_K.gguf"
CTX=${CTX_SIZE:-65536}
THREADS=32
BATCH_SIZE=${BATCH_SIZE:-4096}
N_GPU_LAYERS=999
# NOTE: Gemma 4 uses shared KV layers (tensor views), which crash with row-split
# on multi-GPU due to ggml-cuda.cu:868 assert (view_src == nullptr).
# This is a known upstream bug (github.com/ggml-org/llama.cpp/issues/21420).
# Using layer-split until fixed.
TENSOR_SPLIT="24,24"
SPLIT_MODE="layer"

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

echo "[startup] Model Architecture: Sparse MoE (26B total, 3.8B active per token)"
echo "[startup] Quant: UD-Q6_K (~22GB, smaller than Q8_0 — more VRAM headroom)"
echo "[startup] Model: $MODEL"
echo "[startup] Context Size: $CTX"
echo "[startup] Batch Size: $BATCH_SIZE"
echo "[startup] N GPU Layers: $N_GPU_LAYERS (full offload)"
echo "[startup] Tensor Split: $TENSOR_SPLIT"
echo "[startup] Split Mode: $SPLIT_MODE"

echo "[startup] CRITICAL: Forcing MMQ kernels for Pascal GPUs..."
export GGML_CUDA_FORCE_MMQ=1

echo "[startup] Starting llama-server with Gemma 4 26B-A4B Q6_K..."

exec /app/llama-server \
  -m "$MODEL" \
  -c "$CTX" \
  --host 0.0.0.0 \
  --port 8080 \
  --threads "$THREADS" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size 512 \
  --flash-attn off \
  --parallel 1 \
  -ngl "$N_GPU_LAYERS" \
  -sm "$SPLIT_MODE" \
  -ts "$TENSOR_SPLIT" \
  -ctk f16 \
  -ctv f16 \
  --mlock \
  --metrics
