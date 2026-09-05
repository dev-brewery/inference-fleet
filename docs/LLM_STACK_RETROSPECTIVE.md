# LLM Stack Retrospective (EPYC 7302 + Dual Tesla P40)

Date: 2026-03-06  
Scope: Local inference + routing + OpenWebUI integration for reliable daily-driver usage.

## 1) System + Goal

Hardware baseline:
- CPU: AMD EPYC 7302
- RAM: 128 GB DDR4-2666
- GPU: 2x Tesla P40 (24 GB each)

Primary objective:
- Build a reliable, always-on local LLM "brain" for mixed workloads (general assistant, coding, smart-home/automation orchestration).
- Prioritize reliability and consistency over peak benchmark speed.

Secondary objective:
- Keep a single OpenAI-compatible endpoint path for clients where practical.

## 2) What We Tested

### 2.1 Local backend path
- Continued with `llama.cpp`/`ik_llama.cpp`-class runtime for P40 compatibility.
- Confirmed model residency and active decode on both GPUs.

### 2.2 Router/gateway path
- Built a separate project: `llm-gateway`.
- Implemented LiteLLM routing aliases:
  - `daily-driver` (local backend)
  - `daily-fallback` (local fallback)
  - `coder-primary` (remote host at `coder-host.lan:1234`)
- Validated direct gateway path and model listing behavior.

### 2.3 OpenWebUI integration
- Verified OpenWebUI can list gateway models.
- Identified repeated auth-header inconsistencies on chat-completion path from OpenWebUI host for this gateway endpoint.

### 2.4 Benchmark and behavior checks
- Short-form decode on local dense path commonly around ~10-12 tok/s.
- Remote LM Studio coder path measured around ~17-18 tok/s for short coding prompts.
- GPU utilization observed roughly ~66-70% during active inference.

## 3) What Worked

1. Local dense inference on dual P40 is operational and stable for daily-driver use.
2. Router architecture itself works (alias routing + remote coder target reachable and usable).
3. OpenWebUI can discover models from gateway when endpoint is reachable.
4. Versioning/gating workflow created in `deeply-tuned/versioning` gives a repeatable pass/fail process.
5. Routing to remote coder host (`qwen3-coder-30b-a3b-instruct`) produced usable coding outputs when prompt contract is strict.

## 4) What Did Not Work (or Worked Poorly)

1. vLLM-centric stack ideas are not appropriate for local P40 path (compute capability mismatch for intended use).
2. "More layers" experiments without strict validation increased failure modes (stream hangs, auth confusion, endpoint ambiguity).
3. OpenWebUI + multi-provider + per-provider key behavior was inconsistent for chat calls to gateway in this environment.
4. Prompts with very large effective context caused heavy latency spikes and queue contention, perceived as broken inference.
5. Large "thinking-first" model modes were poor daily-driver candidates for strict coding or deterministic agent workflows.

## 5) Root Causes We Actually Observed

1. **Auth header absent on chat calls from OpenWebUI host to gateway** (seen in gateway logs):
   - `/v1/models` could succeed while `/v1/chat/completions` failed when auth enforcement was enabled.
2. **Queueing/long prompt pressure**:
   - Single heavy decode stream plus large prompt windows causes timeout symptoms and poor perceived responsiveness.
3. **Architecture mismatch assumptions**:
   - Some external stack recommendations assumed newer GPUs and do not transfer directly to Pascal-era cards.

## 6) Current Practical Baseline (Recommended "Known Good")

1. Keep local inference core on `llama.cpp` path.
2. Keep router only where it adds clear value (remote specialist model routing, failover policy).
3. Use strict output contracts for coding and automation prompts:
   - low temperature
   - bounded max tokens
   - explicit response format
4. Keep OpenWebUI reverse proxy tuned for streaming/timeouts (Nginx buffering off, long read/send timeouts).
5. Treat giant context payloads as an explicit "slow path," not default daily-driver traffic.

## 7) What To Explore Next (High Value, Low Risk)

### 7.1 Performance tuning (controlled A/B only)
- A/B `threads` on llama.cpp (e.g., 16 vs 20 vs 24).
- Re-test `batch`/`ubatch` in small increments with fixed prompt shape.
- Keep one-variable-at-a-time policy with logged results.

### 7.2 Reliability hardening
- Add rate/concurrency limits to avoid request pile-up under long generations.
- Add explicit max context budget per request class.
- Keep "heavy long-run" tasks segregated from interactive daily-driver channel.

### 7.3 Routing policy maturity
- Explicit task-to-model map:
  - coding -> `coder-primary`
  - general planning/execution -> `daily-driver`
  - fallback -> `daily-fallback`
- Add periodic health probes per route and automatic disable on repeated backend failure.

### 7.4 Security once behavior is stable
- Re-enable strict auth end-to-end only after OpenWebUI request-header behavior is deterministic.
- Enforce network-level restrictions for gateway port as interim control.

## 8) What Not To Do Next

1. Do not re-architect around vLLM locally on P40.
2. Do not add extra proxy layers without a measured requirement.
3. Do not run broad config churn in production path without gated candidate testing.
4. Do not judge stack health on single ad-hoc runs; rely on scripted regressions.

## 9) Decision Summary

Current phase is operational stabilization, not architecture replacement.

Interpretation:
- "If it isn't broken, don't refactor it" is correct for the local inference core.
- Invest effort in repeatable routing policy, request shaping, and test-gated changes.
- Use remote hosts for specialist throughput where they clearly outperform local hardware.

---

## Appendix A: Key Paths

- Local tuning/runtime project: `~/llm-hosts/deeply-tuned`
- Gateway project: `~/llm-hosts/llm-gateway`
- Versioning/gates: `~/llm-hosts/deeply-tuned/versioning`

## Appendix B: Minimal Validation Commands

Gateway models:
```bash
curl -sS http://llm-box.lan:4000/v1/models
```

Daily-driver chat:
```bash
curl -sS http://llm-box.lan:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"daily-driver","messages":[{"role":"user","content":"Reply exactly OK"}],"max_tokens":8,"temperature":0.0}'
```

Local backend health:
```bash
curl -sS http://llm-box.lan:8080/health
```

---

## Update — 2026-09-04 (Six Months Later)

The retrospective above is the March 2026 record. This section records what changed since, which March conclusions survived, and which aged badly.

### What evolved
- **Router:** `llm-gateway` (LiteLLM) was replaced by `smart-proxy` — a Python-stdlib routing proxy on port 4000 with alias routing, Portainer stack swapping, per-model concurrency caps, a Z.AI quality gate (LLM judge + tool nudge), and structured REQLOG request logging. Every "what to explore next" item from §7 shipped inside it: rate/concurrency limits (per-model, worst-observed caps), health probes with breaker/cooldown, and request logging.
- **Model lineup:** four GPU stacks became twelve (Gemma 4, Qwen 3.6 SSM-hybrid, Qwen 3.8 dense/MoE variants), most with vision via mmproj. The current workhorse is Qwen3.8-27B dense Q6_K — 4 parallel slots + MTP speculative decoding.
- **Cloud tier:** formalized Z.AI through the quality gate with measured worst-observed concurrency caps and a proxy-side upstream routing map that collapses every legacy model id onto the two real pools (glm-5.3, glm-5.3-flash).

### Baselines, then vs now
| Path | March 2026 | September 2026 |
|------|-----------|-----------------|
| Local dense decode | ~10-12 tok/s | ~13-17 tok/s single-stream (MTP speculative decoding); ~15 tok/s concurrent across 4 slots |
| Remote coder | ~17-18 tok/s | unchanged — still the coding fast path |
| Fast MoE path | — | Gemma 4 26B-A4B Q8 at 41 tok/s |

The March conclusion — **operational stabilization, not architecture replacement** — held completely. The llama.cpp core was never replaced; every throughput win came from parallelism, speculative decoding, and routing policy.

### March conclusions that aged badly
1. **"Always restart affected stacks after editing bind-mounted files"** — restarts turned out to be insufficient: bind mounts and image layers resolve at container CREATE time, so stop/start silently serves old code. Container *recreation* (Portainer PUT redeploy, Env preserved) is required. Verified in production 2026-09-04; see TIERED_INFERENCE_FINDINGS.md §6.
2. **Split-mode guidance** — the row-split recommendation died upstream on 2026-07-06 when llama.cpp removed `-sm row` (commit 74976e1ae). Layer split measures 8.46 t/s single-stream on P40; `--parallel 4` + MTP recover ~15 t/s. See BACKEND_RESEARCH.md UPDATE U1.
3. **"Do not add extra proxy layers"** — still true in spirit, but the one proxy that exists grew a quality gate, concurrency accounting, and an upstream routing map. The lesson refined: don't add *layers*; do let the single layer you have absorb policy.
