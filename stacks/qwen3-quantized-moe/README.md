# Qwen3-Coder-Next on Dual Tesla P40

Optimized configuration for running **Qwen3-Coder-Next**, a sparse Mixture-of-Experts (MoE) model with 80B total parameters (3B active per token), on dual Tesla P40 GPUs (24GB each, 48GB total).

## Quick Start

```bash
# 1. Download model (~39GB) using the helper script
cd ~/llm-hosts/qwen3-quantized-moe
./download_model.sh

# 2. Run the optimized script
./run_qwen3.sh
```

The download script will:
- Install `huggingface-cli` if needed
- Allow you to select from multiple model sources
- Automatically resume if the download is interrupted

## Model Architecture

Qwen3-Coder-Next is a **sparse Mixture-of-Experts (MoE)** model:

| Attribute | Value |
|-----------|-------|
| Total Parameters | 80 billion |
| Active Parameters | 3 billion (per token) |
| Architecture | Sparse MoE with routing |
| Release | February 2026 |
| Context Window | Up to 32k tokens |
| Capability | Sonnet 4.5-level coding |

### Key MoE Characteristics

**The MoE Memory Dilemma:**
- **Misconception:** Because only 3B parameters are "active", the model should only need 3B worth of VRAM
- **Reality:** The full 80B parameter weights must be loaded into memory regardless of how many are active per token. During inference, the model routes each token to specific experts, but all 80B weights must be resident in GPU memory for the routing mechanism to access them

**Performance Impact:**
- Only 3B parameters computed per token vs 72B dense models
- 2-3x faster generation speed (estimated 25-40 t/s)
- Lower compute per token = faster generation
- Specialized architecture optimized for coding tasks

## Hardware

- **GPU:** 2x Tesla P40 (24GB VRAM each, 48GB total)
- **Architecture:** Pascal GP102 (sm61, FP32 only)
- **CPU:** AMD EPYC 7302 (16 cores/32 threads)
- **RAM:** 128GB DDR4-2666
- **Interconnect:** PCIe 3.0 x16, NO NVLink

## Expected Performance

| Metric | Qwen3-Coder-Next Q3_K_M | Qwen2.5-72B Q4_K_M |
|--------|-------------------------|-------------------|
| Model Size | ~39 GB | ~47 GB |
| VRAM Usage | ~37-38 GB | ~45-46 GB |
| Speed (est.) | 25-40 t/s | 10-15 t/s |
| Context | Up to 16k | 4-8k typical |
| VRAM Headroom | ~10 GB | ~1-2 GB |
| Coding Quality | Sonnet 4.5-level | High-end |

## Why Qwen3-Coder-Next?

### Advantages

1. **Speed:** 2-3x faster than dense 72B models (25-40 t/s vs 10-15 t/s)
   - Only 3B parameters active per token vs 72B dense
   - Less compute per token = faster generation

2. **VRAM Headroom:** ~10GB free vs ~1GB on Qwen2.5-72B
   - Can use larger context windows (16k+ vs 4k-8k)
   - More stable, less risk of OOM errors
   - Room for KV cache growth

3. **Per-Token Performance:** Sonnet 4.5-level coding
   - Specialized architecture for coding tasks
   - Better at code generation than dense models

4. **Efficiency:** Better utilization of hardware
   - Sparse architecture aligns well with batch processing
   - Lower power consumption per token

### Disadvantages

1. **Quantization Degradation:** Q3_K_M vs Q4_K_M
   - ~10-15% accuracy loss compared to Q4 quantization
   - May affect reasoning, math, factual recall
   - Q3 on an 80B model loses more absolute information than Q4 on 72B

2. **Long-Context Reasoning:** MoE can struggle with very long contexts
   - Expert routing may become less coherent across 20k+ token contexts
   - Dense models often maintain better coherence for book-length tasks

3. **General Intelligence:** 72B dense > 80B MoE @ Q3
   - For non-coding tasks (creative writing, general reasoning), the 72B dense model may outperform
   - Qwen3-Coder-Next is specifically optimized for coding

## Quantization Options

| Quantization | Model Size | Fits in 48GB? | Quality Impact | Recommendation |
|--------------|------------|----------------|----------------|----------------|
| Q4_K_M | ~52GB | **NO** | N/A | Won't fit |
| Q4_K_S | ~48GB | **Maybe** | High quality | Borderline, high OOM risk |
| Q3_K_M | ~39GB | **YES** | Moderate (~10-15% loss) | **Recommended** |
| Q3_K_S | ~35GB | **YES** | Noticeable (~20-25% loss) | Use if VRAM constrained |
| Q2_K | ~26GB | **YES** | Significant (~35-40% loss) | "Brain damaged" - not recommended |

## Configuration

### Key Settings in `run_qwen3.sh`

```bash
# Model path
MODEL_PATH="/storage/models/Qwen3-Coder-Next-Q3_K_M.gguf"

# Full GPU offload - model is smaller (~39GB)
N_GPU_LAYERS=999

# Larger context with VRAM headroom
CTX_SIZE=16384  # 16k vs 4k on dense models

# Can increase batch size with smaller model
BATCH_SIZE=4096  # vs 2048 on dense models

# Pascal-optimized flags
export GGML_CUDA_FORCE_MMQ=1  # Critical for P40
FLASH_ATTN=off                # 50% slower on Pascal
CACHE_TYPE_K=f16              # Fast, sufficient VRAM
```

### Pascal-Specific Optimizations

All Tesla P40 optimizations from the base configuration are applied:

- **MMQ Kernels:** `GGML_CUDA_FORCE_MMQ=1` - Uses integer/FP32 instead of slow FP16
- **No Flash Attention:** `-fa` is 50% slower on Pascal despite being faster on Ampere
- **Row Split Mode:** Both GPUs compute in parallel for maximum throughput
- **F16 KV Cache:** Fastest cache format with sufficient VRAM headroom

## Decision Framework

### Choose Qwen3-Coder-Next Q3_K_M if:
- Primary use case is **coding/programming**
- Speed is more important than absolute reasoning capability
- You want larger context windows (16k+)
- You want more stable VRAM usage (less OOM risk)

### Keep Qwen2.5-72B Q4_K_M if:
- You need maximum general intelligence/reasoning
- You do creative writing, complex reasoning beyond coding
- You want highest quantization quality (Q4)
- 10-15 t/s is acceptable

### Consider Qwen2.5-3B if:
- Speed is critical (200+ t/s)
- Tasks are simple (basic coding, chat, summarization)
- You're okay with significantly reduced intelligence

## Model Sources

### Primary Source: Unsloth
```
https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF
```

### Alternative Sources
- **Bartowski:** https://huggingface.co/bartowski/Qwen_Qwen3-Coder-Next-GGUF
- **DevQuasar:** https://huggingface.co/DevQuasar/Qwen.Qwen3-Coder-Next-GGUF

### Manual Download with hf CLI

```bash
# Q3_K_M (Recommended)
hf download unsloth/Qwen3-Coder-Next-GGUF Qwen3-Coder-Next-Q3_K_M.gguf --local-dir /storage/models

# Q3_K_L (Better quality, tighter fit)
hf download unsloth/Qwen3-Coder-Next-GGUF Qwen3-Coder-Next-Q3_K_L.gguf --local-dir /storage/models

# IQ4_XS (Borderline fit)
hf download unsloth/Qwen3-Coder-Next-GGUF Qwen3-Coder-Next-IQ4_XS.gguf --local-dir /storage/models
```

All downloads support automatic resume if interrupted.

## Tuning and Benchmarking

See `TUNING_LOG.md` for:
- Benchmark results
- Configuration tuning notes
- Performance comparison with Qwen2.5-72B

## Project Structure

```
~/llm-hosts/qwen3-quantized-moe/
├── README.md           (This file - project documentation)
├── QUICK_REFERENCE.md  (Quick start guide)
├── download_model.sh  (Model download helper using huggingface-cli)
├── run_qwen3.sh        (Optimized launch script)
├── TUNING_LOG.md       (Performance tuning log)
└── bin/                (llama.cpp binaries - symlinked)
    ├── llama-cli
    └── llama-server
```

## Monitoring Performance

### VRAM Usage
```bash
watch -n 1 'nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv,noheader'
```

### GPU Utilization
```bash
nvidia-smi dmon -s u -c 100
```

Both GPUs should be active during generation with row split mode.

## References

### Model Information
- [Qwen/Qwen3-Coder-Next - Hugging Face](https://huggingface.co/Qwen/Qwen3-Coder-Next)
- [Qwen Blog - Qwen3-Coder-Next](https://qwen.ai/blog?id=qwen3-coder-next)
- [Qwen3 Download Page](https://qwen-3.com/en/download)

### Community Benchmarks
- [Running Qwen3-Coder-Next (Q3_K_M) on 16 GB RTX 5060 Ti - GitHub Gist](https://gist.github.com/huytd/6b1e9f2271dd677346430c1b92893b57)
- [Qwen3-Coder-Next on RTX 5060 Ti 16 GB - Reddit](https://www.reddit.com/r/LocalLLaMA/comments/1qwbmct/qwen3codernext_on_rtx_5060_ti_16_gb_some_numbers/)

### Base Optimization Docs
- `~/llm-hosts/ik_llama.cpp-gpu/Pascal GPU LLM Optimization for Speed.md`
- `~/llm-hosts/ik_llama.cpp-gpu/TUNING_LOG.md`
- `~/llm-hosts/ik_llama.cpp-gpu/run_optimized.sh`

## Troubleshooting

### Model Not Found
```
ERROR: Model not found at: /storage/models/Qwen3-Coder-Next-Q3_K_M.gguf
```
**Solution:** Download the model first (see Quick Start section)

### Out of Memory
```
cudaMalloc failed: out of memory
```
**Solutions:**
- Reduce `CTX_SIZE` (try 8192 or 4096)
- Reduce `BATCH_SIZE` (try 2048 or 1024)
- Check VRAM usage with `nvidia-smi`

### Slow Performance (< 20 t/s)
**Check:**
- `GGML_CUDA_FORCE_MMQ=1` is set (critical for Pascal)
- Both GPUs are active (`nvidia-smi dmon -s u`)
- `SPLIT_MODE=row` or `graph` (NOT `layer`)
- Flash Attention is OFF

## License

This configuration follows the license of Qwen3-Coder-Next and llama.cpp. Please refer to the respective projects for license details.
