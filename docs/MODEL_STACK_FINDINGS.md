# Model Stack Findings: Compiling, Deploying, and Benchmarking the GPU Fleet

Date: 2026-09-04
Scope: February–September 2026 — twelve GPU stacks compiled from source, deployed as
Portainer stacks, and benchmarked on 2x Tesla P40 + EPYC 7302 (128GB). This is the
fleet-side companion to TIERED_INFERENCE_FINDINGS.md (proxy/cloud/tiering) and
BACKEND_RESEARCH.md (backend selection). Every number below names the file it came from.

Reader's note: the value here is not the numbers — it's the reversals. Roughly half of
what we "knew" in March was wrong or expired by September, and every correction below has
a measurement behind it. That is the actual finding: performance guidance is perishable
at the pace of upstream, and only dated, sourced measurements survive. §0 catalogs the
reversals themselves — and the class of evidence behind each — as the framing for the
blog series.

---

## 0) Catalog of reversals — the discovery journey

The sections below give current answers. The series should convey how the answers
*changed*, because that is the actual discovery process — and it behaves like nutrition
science and eggs: early evidence says the thing is bad, later evidence says it is good
*in some contexts*, and the mature answer is not a flip but a **condition** — "wrong for
these architectures, required for those" — with the deciding variable named. A verdict
without its mechanism expires; the mechanism survives the verdict.

### The evidence ladder (in the order we learned to trust it)

1. **Community claims** — Reddit threads, GitHub issues, vendor blogs. Where "FA is 50%
   slower on Pascal," "graph mode is 40% faster," and "row beats layer" all came from.
   Cheap, often right, occasionally catastrophically wrong (graph mode crashes Pascal
   outright).
2. **Ad-hoc single measurements** — our own numbers, one config, no controls. Better
   than folklore; the 153→29 regression was visible this way, but not attributable.
3. **Controlled single-variable A/B on our hardware** — the 2026-03-04 benchmark that
   separated row/layer/graph and exposed the crash. The moment a number became
   trustworthy.
4. **Source verification** — reading the kernel-selection code (MMQ always-on; dead env
   var) and the driver's reported memory (23040 MiB). Settles *what the flag even does*.
5. **Runtime artifact inspection** — the running binary's own system info
   (`AVX = 1 | AVX2 = 1 | ...`). Settles *what we are actually running* — beats
   build-directory archaeology.
6. **Production evidence over time** — months of deployment (the FA matrix; on the
   proxy side, Z.AI's silent pool moves). Settles *what keeps being true under load*.

### The catalog

| Claim | First believed | Basis | Revised to | Overturning evidence (class) |
|---|---|---|---|---|
| Flash Attention must be OFF | Mar 2026 | community + era measurements (issue #19020) | Per-family: OFF on gemma4/legacy, ON on SSM hybrids — llama.cpp *requires* it for q8_0 KV, which buys 262k context | deployed matrix + quantized-KV requirement (source + production, §4) |
| `GGML_CUDA_FORCE_MMQ=1` is critical | Feb 2026 | community guidance | Dead code on upstream — MMQ is always selected on CC 6.1; kernels were never off | kernel-source read (source, §3) |
| Row split is the P40 default | Feb 2026 | community + our own A/B (12-14 vs 7 t/s) | Was correct, then expired twice: ik fork replaced it with a Pascal-crashing mode; upstream removed it 2026-07-06. Current recipe: layer + `--parallel` + MTP | clean A/B + upstream commits (A/B + source, §2) |
| Graph mode is the next 30-40% win | Mar 2026 | vendor blog | Crashes Pascal: illegal memory access in ROPE | one run on real hardware (§2) |
| Build has AVX2 disabled; recompile for +15-30% | Mar 2026 | cmake cache defaults | The running binary already printed AVX2 = 1 — the "fix" was redundant | running binary's system info (runtime, §5) |
| We have 48GB of VRAM | Feb 2026 | spec sheet | 23040 MiB usable per GPU (45 GiB total); ~6% driver reserve | nvidia-smi + OOM history (source + measurement, §6) |
| Concurrency caps are static numbers (proxy) | Sep 2026 | small synthetic requests | Dynamic by load window; a cap is a worst-observed defense, not a promise | real-payload stress (production; TIERED_INFERENCE_FINDINGS.md §5) |

### What survived unchanged (the control group)

CUDA as the only viable backend; CUDA arch 61; vLLM non-viability (re-confirmed by
experiment, not just docs); sparse MoE as the biggest throughput lever on this hardware;
Q6_K as the fleet default; and the meta-rule born from the regression — single-variable
changes. The pattern: the survivors are either **hardware facts** or rules with a
**mechanism attached**. Everything that expired was a verdict about a moving target —
upstream code, kernel generations, vendor capacity pools.

---

## 1) The Fleet (as of 2026-09)

One stack runs at a time (swapped via Portainer API in ~30s, 10-min anti-flap cooldown).
All stacks: full offload (`-ngl 999`), ubatch 512, `--mlock`, `--metrics`, port 8080.

| Stack | Model + quant | Split | FA | KV | Ctx | VRAM | Measured / role |
|---|---|---|---|---|---|---|---|
| qwen38-dense-q6 ← active | Qwen3.8-27B dense Q6_K + mmproj | layer (forced*) | on | q8_0 | 262k (4×98k pool) | ~23GB | ~13-17 t/s single, ~15 t/s concurrent; MTP + 4 slots |
| gemma4-moe-q8 | Gemma 4 26B-A4B MoE Q8_0 + mmproj | layer (forced†) | off | f16 | 64k | ~29GB | **41 t/s** — fast path |
| qwen36-moe-q5 | Qwen3.6-35B-A3B MoE UD-Q5_K_M + mmproj | row | on | f16 | 64k | ~25GB | SSM hybrid workhorse; BUILD_FLAGS source-verified |
| qwen36-dense-q6 | Qwen3.6-27B dense Q6_K + mmproj | row | on | q8_0 | 64k | ~21GB | Dense SSM hybrid |
| gemma4-moe-q6 | Gemma 4 26B-A4B MoE UD-Q6_K | layer (forced†) | off | f16 | 64k | ~22GB | Lower-VRAM Gemma (no mmproj) |
| gemma4-dense-q8 | Gemma 4 31B dense Q8_0 | layer (forced†) | off | f16 | 32k | ~34GB | Tight fit — ctx capped for headroom |
| gemma4-dense-q6 | Gemma 4 31B dense Q6_K | layer (forced†) | off | f16 | 64k | ~26GB | Dense Gemma long-context |
| qwen35-opus-q8 | Qwen3.5-27B Opus-distill Q8_0 | row | off | f16 | 16k | ~29GB | Max-quality reasoning; Zen2 malloc tuning |
| qwen35-opus-q6 | Qwen3.5-27B Opus-distill Q6_K | row | off | f16 | 49k | ~22GB | Long-context reasoning |
| qwen3-next-instruct | Qwen3-Next-80B-A3B Q3_K_M | row | off | f16 | 96k | ~39GB | 80B workhorse, batch 16384, `--context-shift` |
| qwen3-quantized-moe | Qwen3-Coder-Next Q3_K_M | row | off | f16 | 96k | ~39GB | Coding specialist |
| deeply-tuned (frozen) | Qwen3-32B Q6_K | row | off | f16 | 32k | ~29GB | Legacy baseline; router-gateway mode, seed 42, every flag env-overridable |

\* upstream llama.cpp removed `-sm row` on 2026-07-06; the qwen38 clone (b94041a98)
postdates it — layer is the only multi-GPU mode in that binary.
† forced by the Gemma 4 shared-KV row-split crash (issue #21420) — see §2.

Backend lineage: the 2026-03-era stacks (deeply-tuned, qwen3-next-instruct,
qwen3-quantized-moe, qwen35-opus) were built on ik_llama.cpp-gpu; everything Gemma-4 and
later is upstream ggmlorg/llama.cpp. Every stack owns its own source clone, compile, and
uniquely-named image — never shared (HARD RULE 2 in CLAUDE.md, after a shared-build
experiment took two stacks down at once).

---

## 2) Split mode: a rule that died twice

The longest arc in the doc store, in five acts.

**Act 1 — row wins (Feb 2026).** `ik_llama.cpp-gpu/README_TUNING.md` +
`benchmark_log.csv`: Qwen2.5-72B started at **2.7–3.6 t/s** in "poor configuration". The
-ngl ladder (partial → full offload) plus row split produced the first daily driver:
**~10.3 t/s gen, 60 t/s prompt**. Standing rule became: row 12-14 t/s vs layer ~7 t/s;
graph mode was rumored to add 30-40%.

**Act 2 — the regression incident (Mar 2026).** A "modernized" rebuild of the same model
changed **four variables at once**: split row→layer, AVX/AVX2 off→on, MMQ runtime
env→compile-time, compression size→speed. Result (`qwen3.5/BACKEND_RESEARCH.md`):
prompt processing collapsed **153 → 29 t/s (5x slower)**; gen moved 7.17 → 8.4. The A/B
that isolated it (2026-03-04, "Say hello", 20 max_tokens, Qwen3.5-27B Q8_0):

| Binary | Split | Prompt t/s | Gen t/s | Status |
|---|---|---|---|---|
| Original ik_llama.cpp-gpu | row | **60** | **10.3** | works |
| New ik fork | layer | 30 | 8.0 | 50% slower |
| New ik fork | graph | — | — | **CUDA CRASH** |

The crash: `ROPE failed - CUDA error: an illegal memory access`. The "40% faster" graph
mode does not run on Pascal at all. Recorded verdict: *"The original binary is OPTIMAL
for this hardware. Do NOT switch."* This incident is the origin of the single-variable
rule now codified in ITERATE_AND_FREEZE_PLAYBOOK.md — a rule written in lost throughput.

**Act 3 — split mode is also a correctness knob (May 2026).** Gemma 4 uses shared KV
layers (tensor views) that **crash row-split** on multi-GPU — `ggml-cuda.cu:868` assert,
upstream issue #21420. All four gemma4 stacks run layer split by necessity, knowingly
paying "~7 t/s instead of ~12-14" (their start.sh headers say so). Qwen architectures
have no such bug and kept row. Lesson: split mode isn't a pure performance dial;
per-architecture memory layout can disqualify the faster mode entirely.

**Act 4 — upstream removes row (Jul 2026).** ggmlorg/llama.cpp deleted `-sm row`
entirely on **2026-07-06 (commit 74976e1ae, PR #24216)**. So row died twice, in two
lineages: the ik fork replaced it with a mode that crashes Pascal, then upstream removed
it outright. Every stack cloned after that date has layer as its *only* multi-GPU mode.

**Act 5 — the win is replaced, not recovered (Aug 2026).** On qwen38-dense (layer
forced): **8.46 t/s single-stream**. Recovery came from features, not flags:
`--parallel 4` → **~15 t/s aggregate**, MTP speculative decoding → **~13-17 t/s
single-stream** (§9). Net: the fleet ended up faster than the row era without row.

> Lesson: date-stamp every flag claim and name the binary it was measured on. When a
> flag disappears upstream, re-measure before assuming regression — the replacement win
> may live somewhere you weren't looking.

---

## 3) MMQ: the "critical" env var that does nothing

**At first:** every start.sh carried `export GGML_CUDA_FORCE_MMQ=1` under the banner
"CRITICAL: Forcing MMQ kernels for Pascal GPUs", and CLAUDE.md listed it as a hardware
constraint.

**What source verification found** (`qwen36-moe-q5/BUILD_FLAGS.md`, 2026-05-18): on
upstream llama.cpp the env var is **dead code**. In `ggml_cuda_should_use_mmq()`, CC 6.1
always selects MMQ anyway — Pascal meets the DP4A minimum (610) and has no `fp16_mma`,
so no code path can select anything else. The env var is never read at runtime; only the
cmake option exists. The qwen36-moe start.sh documents this and drops the export.

**Status:** the underlying claim (INT8/MMQ matmul is the right kernel path for P40) was
always true — only "you must force it" was false. The export survives in older stacks as
a harmless cargo-cult line and in CLAUDE.md as a stale constraint (flagged for
ratification, not silently edited).

---

## 4) Flash Attention: "must be off" → "required for quantized KV"

**At first:** FA off, non-negotiable — Pascal has no Tensor Cores and FA measured ~50%
slower (issue #19020, cited in BACKEND_RESEARCH.md).

**The deployed matrix now:**

| Family | FA | KV | Why |
|---|---|---|---|
| qwen38-dense / qwen36-dense | **on** | q8_0 | llama.cpp **requires** FA for quantized V cache — FA on is the price of q8_0 KV |
| qwen36-moe | **on** | f16 | BUILD_FLAGS.md records FA taking the vec-kernel path on Pascal; deployed as measured-best, no surviving isolated A/B in the doc store |
| gemma4 ×4, qwen35-opus ×2, 80B ×2 | off | f16 | classic rule, still correct for these |

The payoff on the dense hybrids: q8_0 KV is what fits **262k context in ~23GB** on
qwen38. What flipped the rule was not new hardware — it was a new *reason* for the flag
(quantized KV requires it). "FA is slower on Pascal" was a measured fact about a kernel
generation, not a law of the silicon.

> Honesty note: §4's table is the deployed matrix, not a controlled experiment. The
> dense-hybrid FA-on choice is corroborated by the quantized-KV requirement; the
> qwen36-moe FA-on choice is recorded as observed-deployed. We record what was measured
> and no more.

---

## 5) AVX2: the optimization that was already enabled

**At first:** root BACKEND_RESEARCH.md's Priority-1 recommendation was "recompile with
AVX2 — the current build has it disabled; expect 15-30% faster prompt processing."
Later, LOCAL_AGENT_ECOSYSTEM_PLAN.md argued the opposite: AVX2 off *by design* to
preserve CPU headroom (GPU server threads park on CUDA during generation; 66-70% GPU
util observed; EPYC load 0.04-0.17 in production).

**The reconciliation** (qwen3.5/BACKEND_RESEARCH.md, benchmark appendix): the original
binary's own system info printed `AVX = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1`.
The binary everyone was arguing about **already had AVX2 enabled**. The "disabled"
reading came from cmake cache defaults, not the shipped artifact — and the regression
incident's "AVX2 optimization" line was, in its own words, "redundant."

> Lesson: verify the premise before optimizing it. The system info of the *running*
> binary beats build-directory archaeology. Two documents took opposite positions on a
> switch that was already in the right position.

---

## 6) "48GB" is really 45 GiB

nvidia-smi reports 24576 MiB per P40; usable is **23040 MiB** — the driver reserves ~6%
(BUILD_FLAGS.md, 2026-05-18). Budgeting at "48GB" OOMs; the doc store's earliest hard
lesson is literally titled "a 47GB model does not fit in 48GB" (README_TUNING.md).

Fleet consequences: gemma4-dense-q8 (~31GB model) caps context at 32k to keep headroom;
qwen38 fits Q6_K + mmproj + a 393216-token KV pool at ~20.7/21.7 GiB per GPU with
1.3-2.3 GiB to spare (predicted in its start.sh, verified after boot).

Two adjacent measurement notes from the same source: `-ts` takes **proportions**, not
MiB (`1,1` ≡ `24,24`), and P2P peer access between the two P40s was **never confirmed**
— the row-split advantage may be partly PCIe-transfer-bound, which is worth remembering
before mourning row too deeply.

---

## 7) Quantization: measured, not vibes

**Model quant** — deeply-tuned bench-results TSVs (Qwen3-32B, 20-question MCQ suite,
seed 42):

| Quant | MCQ score | Gen t/s | Size |
|---|---|---|---|
| Q8_0 | 15/20 (75%) | 19.6 | ~39.5GB |
| Q6_K | 15/20 (75%) | 20.3 | ~29GB |

Identical accuracy on the suite; Q6_K is *faster* (less memory traffic) and 10GB smaller
(more KV room). That single table set the fleet default: Q6_K daily driver, Q8_0 stretch
goal (deeply-tuned/README.md model ladder).

**KV quant** — q8_0 KV costs **~16% decode speed** (llama.cpp issue #10552, also on
README_TUNING's don't-list) and doubles KV capacity per byte. qwen38 spends that
deliberately: 16% slower decode for **262k context**. Correct for a long-context stack;
would be wrong for a latency-sensitive one. Name the trade before making it.

---

## 8) The chat template mattered more than the quant

Same model, same quant, same seed — only the template changed (deeply-tuned bench
template matrix):

| Template | Score /10 |
|---|---|
| model default | 3-4 |
| chatml | **0** |
| no_think + model template | 3 |

A wrong template zeroed the model. A full quant step (Q8→Q6) moved the score *nothing*
(§7). **Template choice had a larger effect size than any quantization decision we
measured.** Check the template before shopping for quants.

---

## 9) Architecture: what MoE and MTP actually bought

- **MoE**: Gemma 4 26B-A4B (3.8B active/param) runs **41 t/s** where dense 27B runs
  8.5-20 t/s. Sparse activation is the single biggest throughput lever on this hardware
  — larger than every flag decision combined.
- **MTP speculative decoding** (qwen38, `--spec-type draft-mtp`, A/B 2026-08-16):
  **8.46 → ~13.3 t/s single-stream (+57%)**, acceptance rate 0.38-0.63, correctness
  verified. Free speed from the model's own multi-token-prediction layers.
- **`--parallel`** (qwen38 A/B): 1/2/4 slots → **8.46 / 12.8 / 15.0 t/s**. Aggregate
  throughput nearly doubles before per-slot latency degrades — one swapped-in stack can
  serve multiple concurrent clients acceptably.
- **Batch**: 8192 benchmarked in BUILD_FLAGS.md and adopted on qwen38/qwen36-moe; the
  80B stacks run 16384 with `--context-shift` for long agent transcripts.

---

## 10) Benchmark methodology — and one discipline lapse

**What the deeply-tuned suite got right:** MCQ at fixed seed (42) + real-request scoring
+ the template matrix (§8) + stream-stability monitoring + an OpenWebUI-path validation
gate. Every candidate logged in `deeply-tuned/versioning/ledger.jsonl` with explicit
promote/invalidate decisions.

**The gate catching its own operator:** a candidate was promoted on a smoke test alone;
the ledger's artifact rule then *invalidated it* — no OpenWebUI test report — and it was
re-promoted only after the real report existed. The process caught the person running
the process. That story is the best argument in the doc store for gates over judgment.

**The lapse:** `qwen3-next-instruct/TUNING_LOG.md` was created as a template and never
filled in — three identical copies (same md5) full of TBDs, while the real A/B results
lived in start.sh comments and CLAUDE.md. A methodology doc nobody fills is worse than
none: it looks like evidence and isn't. Where results actually live today: start.sh
header comments (surprisingly durable — they travel with the stack), BUILD_FLAGS.md,
bench-results TSVs, and frozen-configs snapshots.

---

## 11) What production actually served

40-hour window on the deeply-tuned stack behind its router gateway
(STACK_STATUS_20260331.md):

- **8,129 requests** processed
- **95.7%** passed the LLM judge on first attempt; **196 tool nudges** injected
- **348 tool_use responses vs 61 end_turn** — an agent workload, not a chat workload
- **0.17% failure rate**, zero manual interventions
- EPYC load **0.04-0.17** the entire window — the CPU tier was nearly idle

The fleet spent its capacity on tool calls, and the hardware was never the bottleneck —
routing and prompting were.

---

## 12) Suggested blog-series mapping

| Post | Source sections |
|---|---|
| "Eggs, cholesterol, and GPU flags" — how six months of evidence turned verdicts into conditions | §0 |
| "The flag we tuned around got deleted" — perishable performance guidance | §2 |
| "Cargo-cult flags: the env var that did nothing" | §3 |
| "When the reason changes, the flag flips" (FA + quantized KV) | §4, §7 |
| "Measure the binary you run" (AVX2 + the 4-variable regression) | §5, §2 Act 2 |
| "Template > quant" — where quality actually lives | §7, §8 |
| "MoE, MTP, and slots: buying speed with architecture" | §9 |
| "The gate caught me cheating" — process over judgment | §10 |

---

## Sources

- `*/start.sh` — per-stack flag matrix and header-comment A/B evidence (all 12 stacks)
- `qwen36-moe-q5/BUILD_FLAGS.md` (2026-05-18) — source-verified MMQ/VRAM/FA analysis
- `qwen3.5/BACKEND_RESEARCH.md` (2026-03-04) — the regression incident + clean A/B
- `ik_llama.cpp-gpu/README_TUNING.md`, `benchmark_log.csv` — Feb 2026 baseline era
- `deeply-tuned/bench-results/*.tsv` — MCQ + template matrices (seed 42)
- `deeply-tuned/README.md`, `deeply-tuned/versioning/` — model ladder, gate ledger
- `STACK_STATUS_20260331.md` — 40-hour production window
- `LOCAL_AGENT_ECOSYSTEM_PLAN.md` — AVX2/CPU-headroom position
- Root `BACKEND_RESEARCH.md` — March baseline (with September UPDATE section)
