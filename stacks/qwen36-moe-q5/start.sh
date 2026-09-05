#!/bin/sh
##############################################################################
# Docker Startup Script for Qwen3.6-35B-A3B (MoE) UD-Q5_K_M on 2x Tesla P40
#
# Backend: upstream ggml-org/llama.cpp (qwen36-server-local image)
# Architecture: qwen35moe — 40 layers, 256 experts (8 active), SSM+attention hybrid
#
# Key differences from Gemma 4 stack:
#   - Row-split (-sm row) instead of layer-split: Qwen MoE does NOT have
#     the shared KV tensor bug that forces Gemma 4 to use layer-split.
#   - No GGML_CUDA_FORCE_MMQ=1: dead code on upstream llama.cpp, MMQ is
#     always used on P40 regardless of this env var.
#   - Larger batch size (8192 vs 4096): BUILD_FLAGS.md benchmarked this.
##############################################################################

MODEL="/models/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q5_K_M.gguf"
MMPROJ="/models/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf"
CTX=${CTX_SIZE:-65536}
THREADS=32
BATCH_SIZE=${BATCH_SIZE:-8192}
N_GPU_LAYERS=999
TENSOR_SPLIT="1,1"
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

echo "[startup] Model Architecture: qwen35moe (Sparse MoE + SSM hybrid, 35B total, 3B active per token)"
echo "[startup] Model: $MODEL"
echo "[startup] Multimodal Projector: $MMPROJ"
echo "[startup] Context Size: $CTX"
echo "[startup] Batch Size: $BATCH_SIZE"
echo "[startup] N GPU Layers: $N_GPU_LAYERS (full offload)"
echo "[startup] Tensor Split: $TENSOR_SPLIT"
echo "[startup] Split Mode: $SPLIT_MODE (row-split — Qwen MoE has no shared KV bug)"

echo "[startup] Starting llama-server with Qwen3.6-35B-A3B..."

exec /app/llama-server \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  -c "$CTX" \
  --host 0.0.0.0 \
  --port 8080 \
  --threads "$THREADS" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size 512 \
  --flash-attn on \
  --parallel 1 \
  -ngl "$N_GPU_LAYERS" \
  -sm "$SPLIT_MODE" \
  -ts "$TENSOR_SPLIT" \
  -ctk f16 \
  -ctv f16 \
  --mlock \
  --metrics \
  --reasoning-budget 1024
