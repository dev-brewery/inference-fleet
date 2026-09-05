#!/bin/sh
##############################################################################
# Stress-Test llama-server — single P40 (pinned via compose device_ids)
# Model: qwen3-30b-thinking (~19 GB)
# Purpose: saturate one P40 with prefill-heavy concurrent requests
##############################################################################

MODEL="/models/qwen3-30b-thinking.gguf"
CTX=${CTX_SIZE:-8192}
THREADS=16
BATCH_SIZE=${BATCH_SIZE:-2048}
UBATCH_SIZE=512
N_GPU_LAYERS=999
PARALLEL_SLOTS=${PARALLEL_SLOTS:-8}

echo "[startup] ======================================================="
echo "[startup] STRESS llama-server (single-GPU mode)"
echo "[startup] ======================================================="
echo "[startup] Purpose:       P40 thermal stress via concurrent prefill"
echo "[startup] Model:         $MODEL"
echo "[startup] Ctx / Batch:   $CTX / $BATCH_SIZE (ubatch $UBATCH_SIZE)"
echo "[startup] Parallel:      $PARALLEL_SLOTS slots"
echo "[startup] ======================================================="

if ! command -v nvidia-smi > /dev/null 2>&1; then
    echo "[startup] WARNING: nvidia-smi not found in container"
else
    echo "[startup] Visible GPU(s):"
    nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader | \
    while IFS=, read -r idx name mem_total mem_free; do
        echo "  GPU $idx: $name  total=$mem_total free=$mem_free"
    done
fi

# Pascal GPU optimizations (load-bearing — see BACKEND_RESEARCH.md)
export GGML_CUDA_FORCE_MMQ=1
export GGML_CUDA_CUBLAS=0

# EPYC 7302 allocator tuning
export MALLOC_TRIM_THRESHOLD_=0
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_ARENA_MAX=2

echo "[startup] Pascal optimizations: MMQ forced, Flash Attention off"
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
  --parallel "$PARALLEL_SLOTS" \
  -ctk f16 \
  -ctv f16 \
  --mlock \
  --metrics
