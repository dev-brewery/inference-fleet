# Backend Performance Research for Qwen3.5-27B on Dual Tesla P40

**System Configuration:**
- **CPU:** AMD EPYC 7302 (Zen 2, 16 cores / 32 threads)
- **CPU SIMD:** AVX, AVX2, FMA, F16C, BMI1/BMI2, SSE4.1/4.2
- **GPU:** 2x NVIDIA Tesla P40 (Pascal GP102, 24GB each, 48GB total)
- **GPU Features:** Compute Capability 6.1, no Tensor Cores, no NVLink
- **Memory:** 128GB DDR4, single NUMA node
- **Interconnect:** PCIe 3.0 x16 per GPU

**Current Model:** Qwen3.5-27B-Q8_0.gguf (~27GB)

---

## Executive Summary

For the specific hardware configuration (AMD EPYC 7302 + 2x Tesla P40), **the CUDA backend is definitively the best choice**. No other backend can match CUDA's performance on NVIDIA GPUs, and the Tesla P40's specific architectural constraints make proper CUDA configuration critical.

**Key Finding:** The current build has **AVX2/SIMD disabled**, which is a significant optimization opportunity for CPU operations.

---

## UPDATE — September 2026: What Six Months of Production Changed

This document is the March 2026 research baseline. Most of it held up. Eight findings did not. Each correction below includes the evidence that overturned the original claim. The fleet-level evidence chain behind U5-U8 lives in MODEL_STACK_FINDINGS.md — whose §0 catalogs the belief-revision history (verdict → mechanism, with the evidence class behind each reversal) across the whole doc store.

### U1. `-sm row` is gone — the split-mode table is obsolete

**At first we thought:** row split (`-sm row -ts 24,24`) was the P40 default choice (12-14 t/s vs ~7 t/s layer split), and graph split looked like the next 30-40% win.

**What actually happened:** upstream llama.cpp removed `-sm row` entirely on **2026-07-06 (commit 74976e1ae, PR #24216)**. Stacks built from clones after that date (qwen38-dense-q6, clone @ b94041a98) must use layer split — there is no row-split flag to reach for.

**Measured on P40, 27B dense Q6_K (qwen38-dense-q6):** layer split alone gives **8.46 t/s single-stream** — the old "layer = ~7 t/s" expectation was roughly right. The recovery came from elsewhere: `--parallel 4` recovers **~15 t/s aggregate** across slots, and MTP speculative decoding lifts single-stream to **~13-17 t/s**. Lesson: when the flag you tuned around disappears upstream, re-measure before assuming regression — parallelism and speculative decoding replaced the split-mode win entirely.

### U2. ik_llama.cpp is not the backend for new stacks

**At first we thought:** the ik_llama.cpp fork's CUDA optimizations were the P40 path (the Priority-1 build instructions below point at `ik_llama.cpp-gpu`, and the sources cite an ik optimization guide).

**What we learned:** ik_llama.cpp requires Turing+ GPUs — P40 is Pascal (CC 6.1). One attempt to build a new stack on it was blocked pre-build ("it has optimizations" — it would have failed compilation or produced broken binaries). The binding rule since 2026-09: **backend for all new stacks is upstream ggml-org/llama.cpp**, enforced by a PreToolUse hook (`.claude/hooks/build-enforcer.sh`). The legacy fork directory remains only for the pre-existing stacks built from it.

### U3. vLLM: ruled out by experiment, not just by docs

The `qwen3-next-instruct-vllm/` directory is the experiment record. Conclusion: compute capability 6.1 is too old for vLLM — not viable on Pascal, full stop. CUDA (llama.cpp) remains the only viable GPU backend on this hardware, which only strengthens the March conclusion.

### U4. The "expected" performance tables are now measured tables

March numbers were research-time estimates. Measured production values (2026-09): **27B dense Q6_K + layer split + `--parallel 4` + MTP: ~13-17 t/s single-stream, ~15 t/s concurrent** (vs the March estimate of 7-10 t/s for 27B Q8_0). The 70B Q4_K_M row was never built — treat it as untested; the 80B MoE models that were built run Q3_K_M as the workhorse baseline (~10-12 t/s).

**What held up completely:** CUDA arch 61, and CUDA as the only viable GPU backend on this hardware. **What later fell (U5-U8 below):** MMQ force-on (the env var is dead code — the kernels were always on), Flash Attention off as a blanket rule (the SSM-hybrid stacks deploy FA on), the AVX2-recompile premise (the running binary already had it), and the 48GB VRAM figure (usable is 45 GiB).

### U5. MMQ is always on — the "force it" env var is dead code

**At first we thought:** `GGML_CUDA_FORCE_MMQ=1` was a critical runtime toggle (the runtime block above still exports it, as do most start.sh files).

**What source verification found** (`qwen36-moe-q5/BUILD_FLAGS.md`, 2026-05-18): on upstream llama.cpp, `ggml_cuda_should_use_mmq()` selects MMQ unconditionally on CC 6.1 — Pascal meets the DP4A minimum (610) and has no `fp16_mma`, so no other kernel path is selectable. The env var is never read at runtime (it exists only as a cmake option). The recommendation was harmless; the mechanism claim was false. The qwen36-moe start.sh documents this and drops the export. Full story: MODEL_STACK_FINDINGS.md §3.

### U6. The AVX2 recompile recommendation was solving a solved problem

**At first we thought:** "the current build has AVX2/SIMD disabled" (the CPU SIMD block below) — Priority 1 was a recompile worth 15-30% prompt processing.

**What the benchmark found** (`qwen3.5/BACKEND_RESEARCH.md` appendix, 2026-03-04): the original binary's own system info printed `AVX = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1`. AVX2 was already enabled in the running artifact; the "disabled" reading described cmake cache defaults. The March regression rebuild included this redundant "optimization" as one of its four simultaneous changes — part of why nothing was attributable until the clean A/B. Full story: MODEL_STACK_FINDINGS.md §5.

### U7. "Flash Attention off" is per-family now, not universal

**At first:** FA off always — ~50% slower on Pascal (issue #19020).

**Deployed since mid-2026:** the SSM+attention hybrid stacks run `--flash-attn on`. qwen38-dense and qwen36-dense *require* it — llama.cpp mandates FA for quantized V cache, and their `-ctv q8_0` is what buys qwen38 its 262k context in ~23GB. qwen36-moe runs FA on with f16 KV (vec-kernel path per BUILD_FLAGS.md; recorded as deployed-best). The pre-hybrid stacks (gemma4, qwen35-opus, 80B MoE) keep FA off, correctly. A measured fact about one kernel generation was mistaken for a law of the hardware. Deployed matrix: MODEL_STACK_FINDINGS.md §4.

### U8. The VRAM line item: 45 GiB, not 48

nvidia-smi reports 24576 MiB per P40; usable is **23040 MiB** — the driver reserves ~6% (BUILD_FLAGS.md, 2026-05-18). Budgeting at "48GB" OOMs; the earliest lesson in the doc store is "a 47GB model does not fit in 48GB" (README_TUNING.md). Two adjacent notes from the same verification: `-ts` takes proportions, not MiB (`1,1` ≡ `24,24`), and P2P peer access between the two P40s was never confirmed. Full story: MODEL_STACK_FINDINGS.md §6.

---

## Available Backends Analysis

### 1. CUDA Backend (RECOMMENDED)

**Source:** `ggml/src/ggml-cuda/`
**CMake Option:** `-DGGML_CUDA=ON`

#### Advantages for Tesla P40
| Feature | Status | Notes |
|---------|--------|-------|
| Native NVIDIA support | Excellent | First-class backend for NVIDIA GPUs |
| MMQ Kernels | Available | Critical for Pascal - uses `__dp4a` INT8 instructions |
| Multi-GPU support | Excellent | Row/Graph split modes for dual GPU |
| CUDA Graphs | Supported | Reduces kernel launch overhead |
| Memory management | Mature | VMM support, peer-to-peer access |

#### Pascal-Specific Considerations
- **FP16 Performance:** 1/64th of FP32 (0.18 vs 11.76 TFLOPS) - MUST avoid
- **INT8 Performance:** 47 TOPS via `__dp4a` instruction - USE MMQ kernels
- **Flash Attention:** 50% SLOWER on Pascal - MUST disable
- **Compute Capability:** 6.1 - requires `-DCMAKE_CUDA_ARCHITECTURES=61`

#### Performance Expectations
| Model Size | Quantization | Expected Speed | VRAM Usage |
|------------|--------------|----------------|------------|
| 27B (Qwen3.5) | Q8_0 | 7-10 t/s | ~32GB |
| 70B (Qwen2.5) | Q4_K_M | 10-15 t/s | ~45GB |

#### Required Configuration
```bash
# Build flags
cmake -DGGML_CUDA=ON \
      -DGGML_CUDA_FORCE_MMQ=ON \
      -DCMAKE_CUDA_ARCHITECTURES=61 \
      -DGGML_AVX2=ON \
      -DGGML_FMA=ON \
      -DGGML_F16C=ON

# Runtime flags
export GGML_CUDA_FORCE_MMQ=1
./llama-server -m model.gguf -sm row -ts 24,24 -fa off
# NOTE 2026-09: `-sm row` no longer exists upstream (removed 2026-07-06).
# Post-74976e1ae builds use layer split + --parallel 4 (+ MTP where
# supported) — see UPDATE U1. The MMQ env var is dead code (U5) and "-fa off"
# is now per-family, not universal (U7).
```

---

### 2. HIP/ROCm Backend (NOT APPLICABLE)

**Source:** `ggml/src/ggml-hip/`
**CMake Option:** `-DGGML_HIP=ON`

#### Assessment
- **Designed for:** AMD GPUs (Radeon Instinct, consumer Radeon)
- **Hardware compatibility:** NOT compatible with NVIDIA Tesla P40
- **Verdict:** **Cannot be used** - requires AMD GPU hardware

---

### 3. Vulkan Backend (NOT RECOMMENDED)

**Source:** `ggml/src/ggml-vulkan/`
**CMake Option:** `-DGGML_VULKAN=ON`

#### Theoretical Advantages
- Cross-platform GPU support
- Works on AMD, Intel, and NVIDIA
- Flexible memory management with sysmem fallback

#### Disadvantages for Tesla P40
| Issue | Impact |
|-------|--------|
| Abstraction overhead | 10-30% slower than native CUDA |
| No Pascal-specific optimizations | Lacks MMQ kernel tuning |
| Less mature NVIDIA support | CUDA backend always preferred for NVIDIA |
| No INT8 optimizations | Misses P40's 47 TOPS INT8 capability |

#### Verdict
While Vulkan would work, it would be **significantly slower** than CUDA on Tesla P40. Vulkan is primarily useful for:
- AMD GPU users
- Systems without CUDA installed
- Cross-platform deployment requirements

---

### 4. OpenCL Backend (NOT RECOMMENDED)

**Source:** `ggml/src/ggml-opencl/`
**CMake Option:** `-DGGML_OPENCL=ON`

#### Assessment
- **Designed for:** Mobile/embedded GPUs, Adreno GPUs
- **Performance:** Significantly slower than CUDA on NVIDIA
- **Maturity:** Legacy backend, less maintained
- **Verdict:** **Not suitable** for high-performance Tesla P40 inference

---

### 5. SYCL Backend (NOT APPLICABLE)

**Source:** `ggml/src/ggml-sycl/`
**CMake Option:** `-DGGML_SYCL=ON`

#### Assessment
- **Designed for:** Intel GPUs (Arc series), oneAPI ecosystem
- **Hardware compatibility:** NOT optimized for NVIDIA
- **Verdict:** **Cannot be used** - designed for Intel hardware

---

### 6. CPU-Only Backend (SUPPLEMENTARY)

**Source:** `ggml/src/ggml-cpu/`
**CMake Option:** `-DGGML_CPU=ON` (default)

#### CPU Optimization Status (CRITICAL ISSUE)

**Current Build Configuration:**
```
GGML_AVX:BOOL=OFF      ← Should be ON
GGML_AVX2:BOOL=OFF     ← Should be ON
GGML_FMA:BOOL=OFF      ← Should be ON
GGML_F16C:BOOL=OFF     ← Should be ON
GGML_BMI2:BOOL=OFF     ← Should be ON
```

**EPYC 7302 Capabilities:**
```
CPU supports: avx, avx2, fma, f16c, bmi1, bmi2, sse4_1, sse4_2
```

#### Impact of Missing CPU SIMD
| Operation | Impact of Disabled AVX2 |
|-----------|------------------------|
| Prompt processing | 2-4x slower |
| Tokenization | 1.5-2x slower |
| CPU-offloaded layers | 2-3x slower |
| KV cache management | 1.5-2x slower |

#### Verdict
CPU backend should be **compiled with AVX2 support** to accelerate any CPU-based operations. This is critical for the current setup since some operations may still use CPU.

---

## Backend Comparison Matrix

| Backend | P40 Compatible | Expected Performance | Pascal Optimizations | Recommendation |
|---------|----------------|---------------------|---------------------|----------------|
| **CUDA** | Yes | Best (baseline) | MMQ, CUDA graphs | **USE THIS** |
| HIP | No | N/A | N/A | Not applicable |
| Vulkan | Yes | 70-85% of CUDA | None | Not recommended |
| OpenCL | Yes | 50-70% of CUDA | None | Not recommended |
| SYCL | No | N/A | N/A | Not applicable |
| CPU | Yes | 5-10x slower | AVX2 (missing!) | Supplement only |

---

## Multi-GPU Split Mode Analysis

> **OBSOLETE as of 2026-07-06** — upstream llama.cpp removed `-sm row` (commit 74976e1ae, PR #24216). Newer clones offer layer split only; the measured recovery path is `--parallel 4` + MTP speculative decoding. See UPDATE U1 above.

For dual Tesla P40 configuration, split mode selection is critical:

### Split Mode Comparison

| Mode | Description | PCIe Traffic | Performance | Use Case |
|------|-------------|--------------|-------------|----------|
| `layer` | Sequential layers on each GPU | Low | Poor (~7 t/s) | Not recommended |
| `row` | Parallel tensor shards | High | Good (12-14 t/s) | Default choice |
| `graph` | Optimized graph scheduling | Optimized | Best (14-16 t/s) | If available |

### Performance Impact
```
Layer Split:  GPU0: Layers 0-40 → GPU1: Layers 41-80
              One GPU idle at all times
              Expected: 7-8 t/s

Row Split:    Both GPUs compute half of every layer
              Synchronization after each operation
              Expected: 12-14 t/s

Graph Split:  Intelligent node distribution
              Overlapped compute and transfer
              Expected: 14-16 t/s (30-40% improvement)
```

---

## Current Configuration Analysis

### Build Configuration Issues

| Setting | Current | Recommended | Impact |
|---------|---------|-------------|--------|
| `GGML_AVX` | OFF | ON | CPU ops 2-4x slower |
| `GGML_AVX2` | OFF | ON | CPU ops 2-4x slower |
| `GGML_FMA` | OFF | ON | FMA ops missing |
| `GGML_F16C` | OFF | ON | FP16 conversion slow |
| `GGML_CUDA` | ON | ON | Correct |
| `GGML_CUDA_FORCE_MMQ` | OFF (build) | ON | Runtime env var used instead |

### Runtime Configuration Status

| Setting | Current | Status |
|---------|---------|--------|
| `GGML_CUDA_FORCE_MMQ=1` | Set | Correct |
| `-sm row` | Set | Correct |
| `-ts 24,24` | Set | Correct |
| `-fa off` | Set | Correct |
| `--threads 32` | Set | Correct |

---

## Optimization Recommendations

### Priority 1: Recompile with CPU SIMD (HIGH IMPACT)

Rebuild with proper AVX2 support for the EPYC 7302:

```bash
cd ~/llm-hosts/ik_llama.cpp-gpu
mkdir -p build-optimized && cd build-optimized

cmake .. \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FORCE_MMQ=ON \
    -DCMAKE_CUDA_ARCHITECTURES=61 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_AVX=ON \
    -DGGML_AVX2=ON \
    -DGGML_FMA=ON \
    -DGGML_F16C=ON \
    -DGGML_BMI2=ON \
    -DGGML_SSE42=ON \
    -DGGML_NATIVE=OFF

cmake --build . --config Release -j 32
```

**Expected Improvement:** 15-30% faster prompt processing

### Priority 2: Test Graph Split Mode (MEDIUM IMPACT)

Test the graph split mode which may provide 30-40% improvement:

```bash
# Current
-sm row

# Try
-sm graph
```

**Expected Improvement:** Potentially 30-40% faster token generation

### Priority 3: Consider Q4_K_M Quantization (OPTIONAL)

For the 27B model, Q8_0 uses ~27GB. With 48GB VRAM available:

| Quantization | Size | Quality | Speed |
|--------------|------|---------|-------|
| Q8_0 | ~27GB | Best | Baseline |
| Q6_K | ~22GB | Excellent | +5-10% |
| Q5_K_M | ~19GB | Very Good | +10-15% |
| Q4_K_M | ~16GB | Good | +15-20% |

---

## Conclusion

### Backend Selection
**CUDA is the only viable high-performance backend** for Tesla P40 GPUs. All other backends are either:
- Incompatible (HIP, SYCL)
- Significantly slower (Vulkan, OpenCL)
- Supplementary only (CPU)

### Critical Optimization
The **missing AVX2 compilation flags** are the primary optimization opportunity. The current build is not utilizing the EPYC 7302's SIMD capabilities, which impacts:
- Prompt processing speed
- Any CPU-offloaded operations
- Tokenization and preprocessing

### Recommended Actions
1. **Recompile with AVX2 enabled** - Expected 15-30% improvement
2. **Test graph split mode** - Potential 30-40% improvement
3. **Keep CUDA backend** - No alternative offers better performance

---

## Sources

- [llama.cpp CUDA Performance Discussion #15013](https://github.com/ggml-org/llama.cpp/discussions/15013)
- [Tesla P40 Performance on Reddit](https://www.reddit.com/r/LocalLLaMA/comments/17zpr2o/nvidia_tesla_p40_performs_amazingly_well_for/)
- [Pascal GPU Running Discussion #19248](https://github.com/ggml-org/llama.cpp/discussions/19248)
- [Multi-GPU Performance Breakthrough](https://medium.com/@jagusztinl/llama-cpp-performance-breakthrough-for-multi-gpu-setups-04c83a66feb2)
- [Graph Split 40% Faster on Reddit](https://www.reddit.com/r/LocalLLaMA/comments/1pj9r93/now_40_faster_ik_llamacpp_sm_graph_on_2x_cuda_gpus/)
- [Flash Attention on Pascal Issue #19020](https://github.com/ggml-org/llama.cpp/issues/19020)
- [KV Cache Performance Issue #10552](https://github.com/ggml-org/llama.cpp/issues/10552)
- [ik_llama.cpp CUDA Optimization Guide](https://m.blog.csdn.net/gitblog_00236/article/details/154813437)
- [Vulkan Backend Performance Guide](https://m.blog.csdn.net/gitblog_00796/article/details/156668049)
