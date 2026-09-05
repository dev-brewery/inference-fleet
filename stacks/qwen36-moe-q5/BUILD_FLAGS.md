# Qwen3.6-35B-A3B — Verified llama.cpp Build & Runtime Flags

**Backend:** upstream ggml-org/llama.cpp (NOT ik_llama.cpp — requires Turing+, incompatible with Pascal P40 CC 6.1)
**Hardware:** 2x NVIDIA Tesla P40 (Pascal, compute capability 6.1, 23040 MiB usable per GPU = 46080 MiB total)
**Host:** Ubuntu 22.04.5 LTS, kernel 5.15.0-174, AMD EPYC 7302 (16c/32t), 125 GiB RAM
**CUDA:** Toolkit 12.2.140, driver 535.288.01
**Model:** Qwen3.6-35B-A3B UD-Q5_K_M (MoE, 35B total / 3B active per token, ~24.6 GiB)
**Architecture:** `qwen35moe` (LLM_ARCH_QWEN35MOE in llama-arch.h)
**Vision:** mmproj-F16.gguf (~858 MiB)

All flags below verified against llama.cpp source (`common/arg.cpp`, `ggml/CMakeLists.txt`, `ggml/src/ggml-cuda/CMakeLists.txt`, `mmq.cu`, `mmq.h`, `common.cuh`) and the actual hardware on 2026-05-18.

---

## Host Verification (as of 2026-05-18)

| Claim | Source | Verified |
|-------|--------|----------|
| 2x Tesla P40 | `nvidia-smi --query-gpu` | Confirmed: GPU 0 and GPU 1 both Tesla P40 |
| Compute capability 6.1 | `nvidia-smi --query-gpu=compute_cap` | Confirmed: both report 6.1 |
| 24GB VRAM per GPU | `nvidia-smi --query-gpu=memory.total` | **Partially incorrect**: reports 23040 MiB (~22.5 GiB) per GPU, not 24576 MiB (24 GiB). Driver reserves ~1536 MiB (6%). |
| 48GB total VRAM | Sum of 23040 × 2 | **Corrected**: 46080 MiB (~45 GiB) total usable |
| CUDA 12.2 | `nvcc --version` | Confirmed: CUDA 12.2.140 |
| Pascal architecture | `nvidia-smi -q` | Confirmed: "Product Architecture: Pascal" |
| `compute_61` in CUDA toolkit | `nvcc --list-gpu-arch` | Confirmed: `compute_61` listed |
| AMD EPYC 7302 16c/32t | `lscpu` | Confirmed: 1 socket, 16 cores, 32 threads |
| 128GB RAM | `free -h` | **Corrected**: 125 GiB reported (125 GiB ≈ 134 GB, within normal variance for 128 GB installed) |
| `--mlock` support | `ulimit -l` | Confirmed: 16481060 KB (~16 GB) memlock limit on host. Docker containers need `cap_add: IPC_LOCK` and `ulimits: memlock: -1`. |
| Gemma4-moe-server running | `docker ps` | Confirmed: currently active, using 18864 + 16746 = 35610 MiB across both GPUs |

---

## VRAM Budget for Qwen3.6-35B-A3B

| Component | Size |
|-----------|------|
| Model weights (UD-Q5_K_M) | ~24.6 GiB (~25221 MiB) |
| mmproj (F16) | ~0.86 GiB (~878 MiB) |
| KV cache f16, 65k ctx (estimate) | ~8 GiB (64 layers × 4 KV heads × 128 head_dim × 2 K+V × 2 bytes × 65536 tokens) |
| **Total estimated** | **~33.5 GiB** |
| **Total usable VRAM** | **45 GiB (46080 MiB)** |
| **Headroom** | **~11.5 GiB** |

Fits comfortably. Could increase context or use denser KV cache type if needed.

---

## CMake Build Flags

| Flag | Value | Source | Purpose | Verified on host |
|------|-------|--------|---------|------------------|
| `-DGGML_CUDA=ON` | Required | `ggml/CMakeLists.txt`: `option(GGML_CUDA ...)` | Enables CUDA backend | sm_61 supported in CUDA 12.2 |
| `-DCMAKE_CUDA_ARCHITECTURES="61"` | Required | `ggml/src/ggml-cuda/CMakeLists.txt` | Targets Pascal sm_61 only; avoids multi-arch compile. Comment in source: `# 61 == Pascal, __dp4a instruction` | `compute_61` confirmed in nvcc |
| `-DCMAKE_BUILD_TYPE=Release` | Required | Standard cmake | Optimized build | N/A |
| `-DGGML_CUDA_FA=ON` | Default, leave | `ggml/CMakeLists.txt`: `option(GGML_CUDA_FA ...)` | Compiles FlashAttention kernels. On CC 6.1, FA compiles the vec path (not MMA/tile). No harm leaving on. | N/A |
| `-DGGML_CUDA_FA_ALL_QUANTS=OFF` | Default, leave | `ggml/CMakeLists.txt` | Extra FA quant variants. Not needed — FA on Pascal uses vec path, not quant-specific tile paths. | N/A |
| `-DGGML_CUDA_GRAPHS=ON` | Default, leave | `ggml/CMakeLists.txt` | CUDA graphs for reduced kernel launch overhead. Supported on Pascal (CC 6.0+). | N/A |

### NOT needed (despite usage in existing stacks)

| Flag | Why not needed | Evidence |
|------|---------------|----------|
| `-DGGML_CUDA_FORCE_MMQ=ON` | MMQ is already selected unconditionally on P40 | `ggml_cuda_should_use_mmq()` in `mmq.cu`: P40 (CC 6.1) passes DP4A minimum (`GGML_CUDA_CC_DP4A = 610`), then `fp16_mma_hardware_available(61)` returns false, so `!false \|\| ne11 < 64` = true always. MMQ DP4A path is always selected regardless of this flag. |
| `export GGML_CUDA_FORCE_MMQ=1` (runtime env) | Not checked by upstream llama.cpp at runtime. This is a cmake option only, not an environment variable. | `grep -r GGML_CUDA_FORCE_MMQ` in source: only defined via `option()` in cmake and checked as `#ifdef` compile define. No `getenv()` call for it. Existing stacks that set this in start.sh have no effect with upstream llama.cpp. |

### Full cmake command

```bash
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="61" \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j$(nproc) --target llama-server
```

### Deprecated flag names — DO NOT USE
| Deprecated | Replaced by |
|-----------|-------------|
| `LLAMA_CUBLAS` | `GGML_CUDA` (causes FATAL_ERROR) |
| `LLAMA_CUDA` | `GGML_CUDA` (warning) |

---

## Runtime Flags (llama-server)

| Flag | Value | Verified Syntax | Source | P40 Notes |
|------|-------|----------------|--------|-----------|
| `-m` | Model GGUF path | `-m FILE` | `arg.cpp` | `/models/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q5_K_M.gguf` |
| `--mmproj` | Vision adapter | `--mmproj FILE` or `-mm FILE` | `arg.cpp` | `/models/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf` |
| `-c` | Context size | `-c N` or `--ctx-size N` | `arg.cpp` | 65536. KV cache ~8 GiB at f16. Reduce if VRAM tight. |
| `--host` | Bind address | `--host ADDR` | `arg.cpp` | `0.0.0.0` |
| `--port` | Bind port | `--port N` | `arg.cpp` | `8080` |
| `--threads` | CPU threads | `--threads N` or `-t N` | `arg.cpp` | `32` (matches EPYC 7302 16c/32t) |
| `-b` | Logical batch size | `-b N` or `--batch-size N` | `arg.cpp` | `8192` — larger batches process prompts faster but use more VRAM |
| `-ub` | Micro batch size | `-ub N` or `--ubatch-size N` | `arg.cpp` | `512` |
| `--flash-attn` | FA control | `--flash-attn [on\|off\|auto]` or `-fa` | `arg.cpp` | `off` recommended. CLAUDE.md benchmarks: FA is ~50% slower on Pascal. FA on P40 uses vec path — memory savings but not faster. Test `on` vs `off` with this specific model. |
| `--parallel` | Server slots | `--parallel N` or `-np N` | `arg.cpp` | `1`. Each slot allocates full KV cache. P40 VRAM too tight for multiple slots at 65k context. |
| `-ngl` | GPU layers | `-ngl N` or `--n-gpu-layers N` | `arg.cpp` | `999` (full offload) |
| `-sm` | GPU split mode | `-sm {none\|layer\|row}` or `--split-mode` | `arg.cpp` | See Split Mode section below |
| `-ts` | Tensor split ratio | `-ts N0,N1,...` or `--tensor-split` | `arg.cpp` | `1,1` for even split (both GPUs identical 23040 MiB). `24,24` is equivalent. |
| `-ctk` | KV cache K type | `-ctk TYPE` | `arg.cpp` | `f16`. Valid: `f32`, `f16`, `q8_0`, `q4_0`, `q4_1`, `iq4_nl`, `q5_0`, `q5_1`. NOT `bf16` (Pascal has no BF16 compute). |
| `-ctv` | KV cache V type | `-ctv TYPE` | `arg.cpp` | `f16`. V cache is more sensitive to quantization. |
| `--mlock` | Lock model in RAM | `--mlock` (boolean) | `arg.cpp` | Requires `IPC_LOCK` capability in Docker. 125 GiB RAM is sufficient. |
| `--metrics` | Prometheus endpoint | `--metrics` (boolean) | `arg.cpp` | Exposes `/metrics` for monitoring stack |
| `--reasoning-budget` | Thinking token limit | `--reasoning-budget N` | `arg.cpp` | `1024`. -1 = unlimited, 0 = no thinking. |

### Additional flags of interest

| Flag | Syntax | Purpose | P40 relevance |
|------|--------|---------|---------------|
| `--reasoning` | `-rea [on\|off\|auto]` | Enable/disable thinking blocks | `auto` detects from model template |
| `--fit` | `-fit [on\|off]` | Auto-adjust args to fit device memory | Could be useful — lets llama-server figure out max ctx/ngl |
| `--cpu-moe` | `-cmoe` (boolean) | Keep MoE expert weights on CPU | Saves ~20 GiB VRAM at major speed cost |
| `--mmproj-offload` / `--no-mmproj-offload` | boolean | GPU offload for mmproj | Leave default (on) |

---

## P40-Specific Notes

1. **No tensor cores.** P40 (sm_61) has CUDA cores only. MMQ kernels use `__dp4a` (integer dot product), which was introduced with Pascal CC 6.1 — that's exactly what `GGML_CUDA_CC_DP4A = 610` represents.

2. **MMQ is always used on P40.** The `ggml_cuda_should_use_mmq()` heuristic returns true for all batch sizes on CC 6.1. The decision path: P40 passes DP4A minimum → `fp16_mma_hardware_available(61)` returns false → `!false` is true → MMQ selected. Tile sizes 64x64, DP4A code path, no stream-K. Neither the cmake flag nor the runtime env var are needed.

3. **Flash Attention on P40** compiles the vec kernel path (not MMA/tile). CLAUDE.md benchmarks from prior work show FA is ~50% slower on Pascal. The `--flash-attn off` recommendation is based on that measurement. FA could save KV cache memory — worth testing `on` vs `off` with this specific model.

4. **`-ts 1,1` vs `-ts 24,24`:** Both produce an even split. The flag takes proportions, not absolute MiB. `1,1` is conventional and clearer.

5. **BF16 is not natively supported** on Pascal. The valid `-ctk`/`-ctv` types for P40 are: `f32`, `f16`, `q8_0`, `q4_0`, `q4_1`, `iq4_nl`, `q5_0`, `q5_1`. Do NOT use `bf16`.

6. **CUDA graphs** are supported on Pascal (CC 6.0+) and enabled by default. No action needed.

7. **P2P peer access:** The `nvidia-smi` query returned no peer-to-peer info, which suggests P2P may not be enabled or available between these P40s. This affects `-sm row` performance (row-split relies on GPU-to-GPU communication). If P2P is unavailable, row-split falls back to copying through host memory, reducing its advantage over layer-split.

---

## Split Mode: Row vs Layer for Qwen3.6-MoE

| Mode | How it works | VRAM usage | Throughput | Communication | Risk |
|------|-------------|------------|------------|---------------|------|
| `row` | Splits weight matrices across GPUs, each computes partial result | Higher (intermediate reduction buffers) | Higher if P2P available | Requires cross-GPU all-reduce | May fail with shared tensors |
| `layer` | Assigns whole layers to different GPUs, pipelines | Lower | Lower (sequential pipeline) | Only at layer boundaries | Safe for all architectures |

Qwen3.6-MoE does NOT have the Gemma 4 shared KV tensor bug (ggml-cuda.cu:868 assert). Row-split should compile and run. However, P2P peer access between the two P40s was not confirmed — if unavailable, row-split's advantage diminishes. Recommend testing row-split first; fall back to layer-split if errors occur or if throughput is worse than expected.

---

## Existing Stack Comparison (what the Gemma 4 stack does differently)

The active `gemma4-moe-q8` stack uses:
- Upstream ggml-org/llama.cpp (same backend — correct choice)
- `-sm layer -ts 24,24` (forced by Gemma 4 shared KV tensor bug, not applicable to Qwen)
- `export GGML_CUDA_FORCE_MMQ=1` in start.sh (no effect on upstream llama.cpp — dead code)
- `--flash-attn off` (correct for P40)
- `--parallel 1` (correct for VRAM constraints)
- Own Docker image `gemma4-server-local:latest` (correct — independent)
