#!/bin/sh
##############################################################################
# qwen3-concurrency — qwen3-30b-thinking on single P40
# Purpose: Maximum power draw via dense 30B model with high concurrency
##############################################################################

MODEL="/models/qwen3-30b-thinking.gguf"
CTX=${CTX_SIZE:-6144}
THREADS=${THREADS:-8}
BATCH_SIZE=${BATCH_SIZE:-2048}
UBATCH_SIZE=${UBATCH_SIZE:-512}
N_GPU_LAYERS=999
PARALLEL_SLOTS=${PARALLEL_SLOTS:-6}
PORT=${PORT:-8080}

echo "[startup] ======================================================="
echo "[startup] qwen3-concurrency — 30B dense model stress test"
echo "[startup] ======================================================="
echo "[startup] Model:         $MODEL"
echo "[startup] Ctx / Batch:   $CTX / $BATCH_SIZE (ubatch $UBATCH_SIZE)"
echo "[startup] Parallel:      $PARALLEL_SLOTS slots"
echo "[startup] Port:          $PORT"
echo "[startup] ======================================================="

if command -v nvidia-smi > /dev/null 2>&1; then
    echo "[startup] Visible GPU(s):"
    nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader | \
    while IFS=, read -r idx name mem_total mem_free; do
        echo "  GPU $idx: $name  total=$mem_total free=$mem_free"
    done
fi

# Pascal GPU optimizations (load-bearing — see BACKEND_RESEARCH.md)
export GGML_CUDA_FORCE_MMQ=1
export GGML_CUDA_CUBLAS=0

# EPYC allocator tuning
export MALLOC_TRIM_THRESHOLD_=0
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_ARENA_MAX=2

echo "[startup] Pascal optimizations: MMQ forced, Flash Attention off"
echo "[startup] Starting llama-server..."

exec /app/llama-server \
  -m "$MODEL" \
  -c "$CTX" \
  --host 0.0.0.0 \
  --port "$PORT" \
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
