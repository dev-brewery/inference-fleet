#!/bin/sh
##############################################################################
# Docker Startup Script for Qwen3.6-27B Dense Q6_K on 2x Tesla P40
#
# Backend: upstream ggml-org/llama.cpp (qwen36-dense-server-local image)
# Architecture: qwen35 — 64 layers (48 DeltaNet + 16 Gated Attention), no MoE
#
# Dense variant runs all 27B params per token — higher quality, lower throughput
# than the MoE variant. Uses Q6_K to ensure VRAM headroom with mmproj loaded.
##############################################################################

MODEL="/models/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q6_K.gguf"
MMPROJ="/models/Qwen3.6-27B-GGUF/mmproj-F16.gguf"
CTX=${CTX_SIZE:-65536}
THREADS=32
BATCH_SIZE=${BATCH_SIZE:-4096}
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

echo "[startup] Model Architecture: qwen35 (Dense, 48 DeltaNet + 16 Gated Attention, 27B total)"
echo "[startup] Model: $MODEL"
echo "[startup] Multimodal Projector: $MMPROJ"
echo "[startup] Context Size: $CTX"
echo "[startup] Batch Size: $BATCH_SIZE"
echo "[startup] N GPU Layers: $N_GPU_LAYERS (full offload)"
echo "[startup] Tensor Split: $TENSOR_SPLIT"
echo "[startup] Split Mode: $SPLIT_MODE (row-split)"

echo "[startup] Starting llama-server with Qwen3.6-27B..."

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
  -ctk q8_0 \
  -ctv q8_0 \
  --mlock \
  --metrics \
  --reasoning-budget 1024
