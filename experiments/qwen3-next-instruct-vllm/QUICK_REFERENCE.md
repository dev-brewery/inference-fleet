# Quick Reference: Qwen3-Coder-Next Setup

## Project Location
```
~/llm-hosts/qwen3-quantized-moe/
```

## Quick Start Commands

### Download Model (~39GB)
```bash
cd ~/llm-hosts/qwen3-quantized-moe
./download_model.sh
```

The download script uses `hf` (Hugging Face CLI) which automatically resumes if interrupted.

### Run Model
```bash
cd ~/llm-hosts/qwen3-quantized-moe
./run_qwen3.sh
```

### Monitor Performance
```bash
# VRAM usage
watch -n 1 nvidia-smi

# GPU utilization (both should be active)
nvidia-smi dmon -s u -c 100
```

## Key Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| Model | Qwen3-Coder-Next-Q3_K_M.gguf | ~39GB |
| Context | 16384 tokens | Can go up to 32k |
| Batch Size | 4096 | Can increase to 8192 |
| GPU Layers | 999 (full offload) | Model fits in 48GB |
| Split Mode | row or graph | Both GPUs parallel |

## Expected Performance

| Metric | Value |
|--------|-------|
| Speed | 25-40 t/s (vs 10-15 for Qwen2.5-72B) |
| VRAM Usage | ~37-38 GB / 48 GB |
| VRAM Headroom | ~10 GB |
| Context | Up to 16k tokens |

## Customization Examples

### Larger Context (32k)
```bash
CTX_SIZE=32768 ./run_qwen3.sh
```

### Smaller Batch Size
```bash
BATCH_SIZE=2048 ./run_qwen3.sh
```

### Graph Split Mode
```bash
SPLIT_MODE=graph ./run_qwen3.sh
```

### Combined Custom Settings
```bash
CTX_SIZE=32768 BATCH_SIZE=8192 SPLIT_MODE=graph ./run_qwen3.sh
```

## File Structure

```
~/llm-hosts/qwen3-quantized-moe/
├── README.md           # Full documentation
├── QUICK_REFERENCE.md  # This file
├── run_qwen3.sh        # Launch script
├── TUNING_LOG.md       # Benchmark results
└── bin/                # Binaries (symlinked)
```

## Troubleshooting

### Model Not Found
```
ERROR: Model not found at: /storage/models/Qwen3-Coder-Next-Q3_K_M.gguf
```
Download model first (see Quick Start)

### Out of Memory
```
cudaMalloc failed: out of memory
```
```bash
# Try smaller context
CTX_SIZE=8192 ./run_qwen3.sh

# Or smaller batch
BATCH_SIZE=2048 ./run_qwen3.sh
```

### Slow Performance
```bash
# Check MMQ is enabled (should be set to 1)
echo $GGML_CUDA_FORCE_MMQ

# Verify both GPUs are active
nvidia-smi dmon -s u
```

## Comparison: Qwen3-Coder-Next vs Qwen2.5-72B

| Metric | Qwen3-Coder-Next | Qwen2.5-72B |
|--------|------------------|---------------|
| Model Size | 39 GB | 47 GB |
| Speed | 25-40 t/s | 10-15 t/s |
| Context | 16k+ | 4-8k |
| VRAM Headroom | ~10 GB | ~1 GB |
| Active Params | 3B (sparse) | 72B (dense) |
| Use Case | Coding | General purpose |

## Model Sources

- **Unsloth (Primary):** https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF
- **Bartowski:** https://huggingface.co/bartowski/Qwen_Qwen3-Coder-Next-GGUF
- **DevQuasar:** https://huggingface.co/DevQuasar/Qwen.Qwen3-Coder-Next-GGUF

## References

- Full documentation: `README.md`
- Tuning log: `TUNING_LOG.md`
- Base optimization: `~/llm-hosts/ik_llama.cpp-gpu/Pascal GPU LLM Optimization for Speed.md`
