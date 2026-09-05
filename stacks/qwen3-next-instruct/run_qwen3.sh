#!/bin/bash
##############################################################################
# Optimized Launch Script for Qwen3-Coder-Next on 2x Tesla P40
##############################################################################
#
# PURPOSE:
#   Run Qwen3-Coder-Next-Q3_K_M.gguf (~39GB) on dual Tesla P40 GPUs
#   with optimizations for the sparse MoE architecture.
#
# HARDWARE:
#   - 2x Tesla P40 (24GB VRAM each, 48GB total, Pascal sm61, fp32 only)
#   - AMD EPYC 7302 (16 cores/32 threads)
#   - 128GB DDR4-2666
#   - PCIe 3.0 x16, NO NVLink
#
# MODEL ARCHITECTURE:
#   Qwen3-Coder-Next is a sparse Mixture-of-Experts (MoE) model:
#   - Total Parameters: 80 billion
#   - Active Parameters: 3 billion (per token)
#   - Only 3B parameters are computed per token, making it 2-3x faster
#   - All 80B parameters must be loaded in VRAM for expert routing
#
# USAGE:
#   1. Ensure model is downloaded to /storage/models/
#   2. Run: ./run_qwen3.sh
#   3. Monitor VRAM: watch -n 1 nvidia-smi
#   4. Adjust parameters as needed (see CONFIGURATION below)
#
# EXPECTED PERFORMANCE:
#   - Speed: 25-40 t/s (estimated, 2-3x faster than dense 72B)
#   - VRAM Usage: ~37-38 GB / 48 GB (comfortable headroom)
#   - Context: Up to 16k tokens (vs 4-8k on dense models)
#
##############################################################################

set -e  # Exit on error

##############################################################################
# CONFIGURATION SECTION - Edit These Parameters
##############################################################################

# ===== Model and Binary Paths =====
MODEL_PATH="${MODEL_PATH:-/storage/models/Qwen3-Coder-Next-Q3_K_M.gguf}"
BINARY_PATH="${BINARY_PATH:-./bin/llama-cli}"

# ===== GPU Layers =====
# Full GPU offload - model is smaller (~39GB vs ~47GB for Qwen2.5-72B)
# Setting to 999 offloads all layers to GPU
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"

# ===== Multi-GPU Configuration =====
# Split mode: row (parallel), layer (sequential), graph (optimized)
# row: Both GPUs compute in parallel, sync after each layer
# graph: Optimized execution graph (ik_llama.cpp feature)
# WARNING: -sm layer leaves one GPU idle - USE ROW OR GRAPH
SPLIT_MODE="${SPLIT_MODE:-row}"

# Tensor split: VRAM allocation per GPU in GB (must sum to total VRAM)
# Equal split for 2x 24GB cards
TENSOR_SPLIT="${TENSOR_SPLIT:-24,24}"

# ===== Memory and Context =====
# Context window size - MoE models have VRAM headroom for larger contexts
# Qwen3-Coder-Next supports up to 32k, but 16k is practical for 48GB VRAM
CTX_SIZE="${CTX_SIZE:-16384}"

# Batch size for processing tokens (larger = faster but more VRAM)
# MoE architecture allows larger batch sizes due to fewer active params
BATCH_SIZE="${BATCH_SIZE:-4096}"

# CPU threads (EPYC 7302 has 32 threads total)
THREADS="${THREADS:-32}"

# ===== Critical Performance Flags =====
# Flash Attention: WARNING - 50% slower on Pascal despite being faster on Ampere!
# Keep OFF for Tesla P40
# Source: https://github.com/ggml-org/llama.cpp/issues/19020
FLASH_ATTN="${FLASH_ATTN:-off}"

# KV cache type: f16 (default, fast) or q8_0 (saves VRAM but 16% slower)
# Use f16 for best performance - Q3_K_M model leaves enough VRAM headroom
CACHE_TYPE_K="${CACHE_TYPE_K:-f16}"

# ===== Sampling Parameters =====
TEMP="${TEMP:-0.7}"
TOP_P="${TOP_P:-0.9}"
REPEAT_PENALTY="${REPEAT_PENALTY:-1.1}"
MIN_P="${MIN_P:-0.05}"
TOP_K="${TOP_K:-40}"

# ===== System Configuration =====
# NUMA interleaving: helps with memory allocation on multi-socket systems
NUMA_INTERLEAVE="${NUMA_INTERLEAVE:-true}"

##############################################################################
# ENVIRONMENT SETUP
##############################################################################

# CRITICAL for Pascal: Force MMQ (integer/FP32) kernels instead of slow FP16
# FP16 on Pascal is 1/64th speed of FP32 (0.18 vs 11.76 TFLOPS)
# Source: Tesla P40 specs, NVIDIA Pascal Tuning Guide
export GGML_CUDA_FORCE_MMQ="${MMQ_ENABLED:-1}"

# Specify which GPUs to use (both cards)
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

##############################################################################
# VALIDATION
##############################################################################

echo "=========================================="
echo "Qwen3-Coder-Next Optimized Launch Script"
echo "=========================================="
echo "Model Architecture: Sparse MoE (80B total, 3B active per token)"
echo ""

# Check if model exists
if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: Model not found at: $MODEL_PATH"
    echo ""
    echo "Qwen3-Coder-Next models must be downloaded first."
    echo ""
    echo "Download options:"
    echo "  1. From HuggingFace (Unsloth):"
    echo "     wget -P /storage/models https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF/resolve/main/Qwen3-Coder-Next-Q3_K_M.gguf"
    echo ""
    echo "  2. From HuggingFace (Bartowski):"
    echo "     wget -P /storage/models https://huggingface.co/bartowski/Qwen_Qwen3-Coder-Next-GGUF/resolve/main/Qwen3-Coder-Next-Q3_K_M.gguf"
    echo ""
    echo "  3. From HuggingFace (DevQuasar):"
    echo "     wget -P /storage/models https://huggingface.co/DevQuasar/Qwen.Qwen3-Coder-Next-GGUF/resolve/main/Qwen3-Coder-Next-Q3_K_M.gguf"
    echo ""
    echo "Expected file size: ~38-39 GB"
    exit 1
fi

# Check if binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found at: $BINARY_PATH"
    echo "Please build llama.cpp first or update BINARY_PATH."
    exit 1
fi

# Check if nvidia-smi is available
if ! command -v nvidia-smi &> /dev/null; then
    echo "WARNING: nvidia-smi not found. Cannot validate GPU configuration."
else
    echo "GPU Configuration:"
    nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader | \
    while IFS=, read -r idx name mem_total mem_free; do
        echo "  GPU $idx: $name"
        echo "    Total VRAM: $mem_total"
        echo "    Free VRAM:  $mem_free"
    done
    echo ""
fi

##############################################################################
# VRAM ESTIMATION
##############################################################################

# Estimate VRAM usage for Qwen3-Coder-Next Q3_K_M
# Q3_K_M 80B MoE model: ~38-39 GB
# KV cache for 16k context: ~6-8 GB (larger than dense models)
# CUDA overhead: ~500 MB - 1 GB per card
MODEL_SIZE_GB=39
KV_CACHE_GB=7
CUDA_OVERHEAD_GB=1
TOTAL_VRAM=48

echo "VRAM Estimation:"
echo "  Model size:        ${MODEL_SIZE_GB} GB"
echo "  KV cache (${CTX_SIZE}):     ${KV_CACHE_GB} GB"
echo "  CUDA overhead:     ${CUDA_OVERHEAD_GB} GB per GPU"
echo ""

ESTIMATED_USAGE=$(echo "scale=2; $MODEL_SIZE_GB + $KV_CACHE_GB + ($CUDA_OVERHEAD_GB * 2)" | bc)
HEADROOM=$(echo "scale=2; $TOTAL_VRAM - $ESTIMATED_USAGE" | bc)

echo "  Estimated VRAM usage: ${ESTIMATED_USAGE} GB / ${TOTAL_VRAM} GB"
echo "  Headroom: ${HEADROOM} GB"
echo ""

# Warn if VRAM usage is high
if (( $(echo "$HEADROOM < 2" | bc -l) )); then
    echo "⚠️  WARNING: VRAM usage is very high! Risk of OOM."
    echo "   Consider reducing CTX_SIZE or BATCH_SIZE."
    echo ""
fi

##############################################################################
# BUILD COMMAND
##############################################################################

CMD="$BINARY_PATH"
CMD="$CMD -m \"$MODEL_PATH\""
CMD="$CMD -ngl $N_GPU_LAYERS"
CMD="$CMD -sm $SPLIT_MODE"
CMD="$CMD -ts $TENSOR_SPLIT"
CMD="$CMD -c $CTX_SIZE"
CMD="$CMD -b $BATCH_SIZE"
CMD="$CMD -t $THREADS"

# Only add flash attention if enabled
if [ "$FLASH_ATTN" = "on" ]; then
    CMD="$CMD -fa"
    echo "⚠️  WARNING: Flash Attention is ENABLED - this is 50% slower on Pascal!"
    echo "   Source: https://github.com/ggml-org/llama.cpp/issues/19020"
    echo ""
fi

# Add cache type if specified
if [ "$CACHE_TYPE_K" != "f16" ]; then
    CMD="$CMD --cache-type-k $CACHE_TYPE_K"
    if [ "$CACHE_TYPE_K" = "q8_0" ]; then
        echo "⚠️  WARNING: q8_0 KV cache causes 16% performance penalty"
        echo "   Source: https://github.com/ggml-org/llama.cpp/issues/10552"
        echo ""
    fi
fi

# Sampling parameters
CMD="$CMD --temp $TEMP"
CMD="$CMD --top-p $TOP_P"
CMD="$CMD --repeat-penalty $REPEAT_PENALTY"
CMD="$CMD --min-p $MIN_P"
CMD="$CMD --top-k $TOP_K"

# Interactive mode - use reverse prompt to enable interactive mode
# Note: conversation mode (-cnv) may not be needed for basic chat
CMD="$CMD -r \"User:\" -p \"User: Hello, can you introduce yourself?\""

##############################################################################
# APPLY NUMA SETTINGS
##############################################################################

if [ "$NUMA_INTERLEAVE" = "true" ]; then
    if command -v numactl &> /dev/null; then
        CMD="numactl --interleave=all $CMD"
        echo "NUMA interleaving enabled"
    else
        echo "⚠️  numactl not found - NUMA interleaving disabled"
    fi
fi

##############################################################################
# DISPLAY CONFIGURATION AND LAUNCH
##############################################################################

echo "=========================================="
echo "Configuration Summary"
echo "=========================================="
echo "Model:              $MODEL_PATH"
echo "Architecture:       Sparse MoE (80B total, 3B active/token)"
echo "N GPU Layers:       $N_GPU_LAYERS (full offload)"
echo "Split Mode:         $SPLIT_MODE"
echo "Tensor Split:       $TENSOR_SPLIT"
echo "Context Size:       $CTX_SIZE"
echo "Batch Size:         $BATCH_SIZE"
echo "CPU Threads:        $THREADS"
echo "Flash Attention:    $FLASH_ATTN"
echo "KV Cache Type:      $CACHE_TYPE_K"
echo "Temperature:        $TEMP"
echo "Top-P:              $TOP_P"
echo "Repeat Penalty:     $REPEAT_PENALTY"
echo "=========================================="
echo ""
echo "Performance Expectations:"
echo "  Estimated Speed:   25-40 t/s (vs 10-15 t/s for Qwen2.5-72B)"
echo "  VRAM Headroom:     ~${HEADROOM} GB (allows larger context)"
echo "  Quality:           Sonnet 4.5-level coding capability"
echo ""
echo "🚀 Launching Qwen3-Coder-Next with optimized settings..."
echo ""
echo "Monitor VRAM usage in another terminal:"
echo "  watch -n 1 'nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv,noheader'"
echo ""
echo "Monitor tokens/second in output (look for 'loading' in prompt line)"
echo ""
echo "=========================================="
echo ""

# Execute command
eval $CMD
