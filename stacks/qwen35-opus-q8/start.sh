#!/bin/sh
##############################################################################
# Docker Startup Script for Qwen3.5-27B Opus-Distilled (Q8_0)
# Optimized for: EPYC 7302 (16c/32t) + 2x Tesla P40 (24GB each, Pascal)
# Purpose: Max quality reasoning, shorter context (16k)
##############################################################################

MODEL="/models/Qwen3.5-27B-Opus-Distilled/Qwen3.5-27B.Q8_0.gguf"
CTX=${CTX_SIZE:-16384}
THREADS=32
BATCH_SIZE=${BATCH_SIZE:-4096}
UBATCH_SIZE=512
N_GPU_LAYERS=999
TENSOR_SPLIT="24,24"
SPLIT_MODE="row"

echo "[startup] ======================================================="
echo "[startup] Qwen3.5-27B Opus-Distilled Q8_0 on 2x Tesla P40"
echo "[startup] ======================================================="
echo "[startup] Purpose: Max quality reasoning (16k context)"
echo "[startup] Model:   Jackrong v2 Claude-4.6-Opus distill"
echo "[startup] Quant:   Q8_0 (~28.6GB, near-lossless)"
echo "[startup] ======================================================="

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

echo "[startup] Model: $MODEL"
echo "[startup] Context Size: $CTX"
echo "[startup] Batch Size: $BATCH_SIZE"
echo "[startup] UBatch Size: $UBATCH_SIZE"
echo "[startup] Threads: $THREADS"
echo "[startup] N GPU Layers: $N_GPU_LAYERS (full offload)"
echo "[startup] Tensor Split: $TENSOR_SPLIT (24GB per GPU)"
echo "[startup] Split Mode: $SPLIT_MODE"

##############################################################################
# PASCAL GPU OPTIMIZATIONS (Tesla P40)
##############################################################################
export GGML_CUDA_FORCE_MMQ=1
export GGML_CUDA_CUBLAS=0

echo "[startup] Pascal optimizations: MMQ forced, Flash Attention off"

##############################################################################
# EPYC 7302 (Zen 2) CPU OPTIMIZATIONS
##############################################################################
export MALLOC_TRIM_THRESHOLD_=0
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_ARENA_MAX=2

echo "[startup] Zen 2 memory allocator tuned"
echo "[startup] Starting llama-server..."

exec /app/llama-server \
  -m "$MODEL" \
  -c "$CTX" \
  --host 0.0.0.0 \
  --port 8080 \
  --threads "$THREADS" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size "$UBATCH_SIZE" \
  --flash-attn off \
  -ngl "$N_GPU_LAYERS" \
  -sm "$SPLIT_MODE" \
  -ts "$TENSOR_SPLIT" \
  -ctk f16 \
  -ctv f16 \
  --mlock \
  --metrics
