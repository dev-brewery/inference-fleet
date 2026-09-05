#!/bin/sh
##############################################################################
# Docker Startup Script for Qwen3.8-27B Dense Q6_K on 2x Tesla P40
#
# Backend: upstream ggml-org/llama.cpp (qwen38-dense-server-local image)
# Architecture: qwen35 — same hybrid arch as Qwen3.6 dense (48 DeltaNet +
#   16 Gated Attention), no MoE. Includes MTP layers, enabled below via
#   --spec-type draft-mtp (A/B verified 2026-08-16: 8.46 -> ~13.3 t/s
#   single-stream (+57%), acceptance 0.38-0.63, correctness verified).
#
# Dense variant runs all 27B params per token — higher quality, lower
# throughput than the MoE variant. Uses Q6_K to ensure VRAM headroom with
# mmproj loaded.
#
# Split mode: LAYER (not row). Upstream llama.cpp removed -sm row entirely
#   on 2026-07-06 (commit 74976e1ae, PR #24216); every build that supports
#   Qwen3.8 (>= b10419) postdates that removal. Layer split is the only
#   multi-GPU mode available. Verified on P40: 8.46 t/s single stream.
#
# Parallel: 4 slots x 98304 ctx (393216 pool), batch 8192 / ubatch 512.
#   Raised from 262144/4096 on 2026-08-25. Concurrency: re-bench post-deploy
#   (prior A/B: 8.46/12.8/15.0 t/s @1/2/4). VRAM predicted ~20.7/~21.7 GiB
#   per GPU (~2.3/~1.3 GiB headroom) — verify after boot.
##############################################################################

MODEL="/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q6_K.gguf"
MMPROJ="/models/Qwen3.8-27B-GGUF/mmproj-F16.gguf"
CTX=${CTX_SIZE:-393216}
THREADS=32
BATCH_SIZE=${BATCH_SIZE:-8192}
N_GPU_LAYERS=999
TENSOR_SPLIT="1,1"
SPLIT_MODE="layer"
PARALLEL=4

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

echo "[startup] Model Architecture: qwen35 (Dense, hybrid SSM+attention, 27B total)"
echo "[startup] Model: $MODEL"
echo "[startup] Multimodal Projector: $MMPROJ"
echo "[startup] Context Size: $CTX"
echo "[startup] Batch Size: $BATCH_SIZE"
echo "[startup] N GPU Layers: $N_GPU_LAYERS (full offload)"
echo "[startup] Tensor Split: $TENSOR_SPLIT"
echo "[startup] Split Mode: $SPLIT_MODE (row removed upstream 2026-07-06)"
echo "[startup] Parallel: $PARALLEL slots"

echo "[startup] Starting llama-server with Qwen3.8-27B..."

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
  --parallel "$PARALLEL" \
  -ngl "$N_GPU_LAYERS" \
  -sm "$SPLIT_MODE" \
  -ts "$TENSOR_SPLIT" \
  -ctk q8_0 \
  -ctv q8_0 \
  --mlock \
  --metrics \
  --reasoning-budget 1024 \
  --spec-type draft-mtp
