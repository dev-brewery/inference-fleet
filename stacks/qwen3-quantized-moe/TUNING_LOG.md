# Tuning Log for Qwen3-Coder-Next on 2x Tesla P40

**Hardware:**
- 2x Tesla P40 (24GB VRAM each, 48GB total)
- AMD EPYC 7302 (16 cores/32 threads)
- 128GB DDR4-2666
- PCIe 3.0 x16, NO NVLink

**Model:** Qwen3-Coder-Next-Q3_K_M.gguf (~39GB)

**Architecture:** Sparse MoE (80B total parameters, 3B active per token)

**Target Performance:** 25-40 t/s (estimated)
**Starting Performance:** TBD

## Comparison: Qwen3-Coder-Next vs Qwen2.5-72B

| Metric | Qwen3-Coder-Next Q3_K_M | Qwen2.5-72B Q4_K_M |
|--------|-------------------------|-------------------|
| Model Size | ~39 GB | ~47 GB |
| VRAM Usage | ~37-38 GB | ~45-46 GB |
| Est. Speed | 25-40 t/s | 10-15 t/s |
| Max Context | 16k+ | 4-8k typical |
| VRAM Headroom | ~10 GB | ~1-2 GB |
| Active Params | 3B (sparse) | 72B (dense) |

## Tuning Results Log

### Test Run Template

Copy this template for each test run:

```markdown
#### Run #X - [Date/Time]

**Configuration:**
- Model: Qwen3-Coder-Next-Q3_K_M.gguf
- N_GPU_LAYERS: [value]
- SPLIT_MODE: [row|layer|graph]
- BATCH_SIZE: [value]
- CTX_SIZE: [value]
- FLASH_ATTN: [on|off]
- CACHE_TYPE_K: [f16|q8_0]

**Results:**
- VRAM Usage (GPU 0): [X] GB
- VRAM Usage (GPU 1): [X] GB
- Total VRAM: [X] GB / 48 GB
- Tokens/Second: [X] t/s
- Time to First Token: [X] ms
- Both GPUs Active: [yes/no]

**Observations:**
- [Any issues, errors, or notable behaviors]

**Verdict:**
- [Increase/Decrease/Keep] parameter
- [Next steps]

---
```

## Test Runs

### Run #1 - Baseline (Initial Setup)

**Configuration:**
- Model: Qwen3-Coder-Next-Q3_K_M.gguf
- N_GPU_LAYERS: 999 (full offload)
- SPLIT_MODE: row
- BATCH_SIZE: 4096
- CTX_SIZE: 16384
- FLASH_ATTN: off
- CACHE_TYPE_K: f16

**Results:**
- VRAM Usage: TBD
- Tokens/Second: TBD
- Both GPUs Active: TBD

**Verdict:**
- TBD

---

## Performance Notes

### Expected Speed Comparison

Based on the MoE architecture and Q3_K_M quantization:

| Configuration | Expected Speed | Notes |
|--------------|----------------|-------|
| Conservative (ngl=60) | ~15-20 t/s | Minimal VRAM usage |
| Moderate (ngl=80) | ~20-25 t/s | Good VRAM usage |
| Full (ngl=999) | ~25-40 t/s | Full GPU offload, target config |

### Speed vs Qwen2.5-72B

Theoretical speedup comes from:
- **3B active parameters** vs 72B dense = 24x fewer FLOPs per token
- **Sparse architecture** = better cache locality
- **Q3_K_M quantization** = less memory bandwidth per parameter

Real-world speedup: **2-3x** (not full 24x due to:
- Expert routing overhead
- Memory bandwidth bound, not compute bound
- PCIe synchronization in multi-GPU setup)

### Known Bottlenecks

1. **PCIe 3.0 x16 (no NVLink):** ~16 GB/s bandwidth per card
   - Row split requires inter-GPU communication
   - Less impactful on MoE due to fewer active parameters
   - Graph split can optimize overlap of compute and transfer

2. **Pascal FP16 Performance:** 1/64th of FP32
   - Must use MMQ kernels (GGML_CUDA_FORCE_MMQ=1)
   - Never use FP16 compute

3. **Flash Attention:** 50% slower on Pascal
   - Keep disabled (default in script)

4. **Expert Routing Overhead:**
   - MoE models have routing overhead not present in dense models
   - Typically adds 5-10% latency vs theoretical minimum

### VRAM Budget

**Total Available:** 48 GB (24 GB per card)

**Fixed Overhead:**
- Model (Q3_K_M 80B MoE): ~39 GB
- KV Cache (16k context): ~6-8 GB (larger than dense models)
- CUDA Overhead: ~0.5-1 GB per card

**Tunable:**
- CTX_SIZE: 4096 to 32768
- BATCH_SIZE: 512 to 8192

**Expected VRAM Distribution (Full Offload):**
```
GPU 0: ~19-20 GB  (model weights + KV cache)
GPU 1: ~19-20 GB  (model weights + KV cache)
Headroom: ~8-10 GB (allows larger contexts)
```

### Critical Sources

- [Qwen3-Coder-Next Model Card](https://huggingface.co/Qwen/Qwen3-Coder-Next)
- [Unsloth Qwen3-Coder-Next GGUF](https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF)
- [ikawrakow Discussion #532](https://github.com/ikawrakow/ik_llama.cpp/discussions/532) - NGL tuning guidance
- [Medium: Multi-GPU performance](https://medium.com/@jagusztinl/llama-cpp-performance-breakthrough-for-multi-gpu-setups-04c83a66feb2) - Split modes
- [Issue #19020: Flash Attention on Pascal](https://github.com/ggml-org/llama.cpp/issues/19020) - FA is 50% slower

## Tuning Workflow

1. **Download model** (if not already done)
   ```bash
   wget https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF/resolve/main/Qwen3-Coder-Next-Q3_K_M.gguf
   ```

2. **Baseline test:** Run with default settings
   ```bash
   ./run_qwen3.sh
   ```

3. **Monitor performance:**
   - VRAM: `watch -n 1 nvidia-smi`
   - GPU utilization: `nvidia-smi dmon -s u -c 100`
   - Tokens/second: Check in output

4. **Tune parameters (if needed):**
   - If VRAM < 45GB: Increase CTX_SIZE or BATCH_SIZE
   - If OOM: Decrease CTX_SIZE or BATCH_SIZE
   - If slow: Check SPLIT_MODE, verify MMQ enabled

5. **Try graph split** (after finding stable config):
   ```bash
   SPLIT_MODE=graph ./run_qwen3.sh
   ```

6. **Document results** in this file using the template above

## Quick Reference Commands

```bash
# Run with custom settings
N_GPU_LAYERS=999 BATCH_SIZE=8192 CTX_SIZE=32768 ./run_qwen3.sh

# Monitor VRAM in real-time
watch -n 1 'nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv,noheader'

# Check GPU utilization (both should be active)
nvidia-smi dmon -s u -c 100

# Run with graph split mode
SPLIT_MODE=graph ./run_qwen3.sh

# Run with larger context
CTX_SIZE=32768 ./run_qwen3.sh
```

## Benchmark Prompts

Use these prompts for consistent testing:

### Coding Task
```
Write a Python function that implements merge sort with detailed comments explaining each step.
```

### Code Debugging
```
Find and fix the bug in this code:
def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)
```

### System Design
```
Design a URL shortening service like bit.ly. Explain the architecture, database schema, and API endpoints.
```

### Math Reasoning
```
A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?
```

### Long Context Test
```
[Paste 1000+ lines of code]
Explain what this code does and suggest improvements.
```

## Performance Goals

### Minimum Viable Performance
- **Speed:** > 20 t/s (2x faster than Qwen2.5-72B)
- **VRAM:** < 42 GB (leave headroom for KV cache)
- **Stability:** No OOM errors during normal use

### Target Performance
- **Speed:** 25-35 t/s (2.5-3x faster than Qwen2.5-72B)
- **VRAM:** ~37-38 GB (comfortable headroom)
- **Context:** 16k tokens stable

### Excellent Performance
- **Speed:** > 35 t/s (3x+ faster than Qwen2.5-72B)
- **VRAM:** ~37-38 GB
- **Context:** 16k+ tokens, stable
- **Quality:** Passes Sonnet 4.5-level coding benchmarks
