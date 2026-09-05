# Tiered Inference: Budget Hardware + Small Local LLMs + Cheap Cloud

Date: 2026-03-29
Scope: Findings from building a production agent ecosystem on consumer/enterprise-surplus hardware with tiered local and cloud inference.

## 1) The Problem

Running AI agents against frontier cloud models is expensive and fragile. API rate limits, credit exhaustion, and per-token costs make it impractical for always-on agent workloads that generate hundreds of requests per hour — most of which are routine (status checks, tool result processing, heartbeats) and don't need a $20/MTok model.

The goal: build an inference stack where agents get frontier-quality responses when they need them, instant CPU responses when they don't, and the system makes the decision automatically — all on hardware that costs less than two months of API bills.

## 2) Hardware Reality

### What we have
- CPU: AMD EPYC 7302 (16c/32t) — $100-150 used
- RAM: 128 GB DDR4-2666 ECC — ~$200 used
- GPU: 2x Tesla P40 (24 GB each, 48 GB total) — ~$150 each used
- Total hardware cost: ~$600-700

### What that gets you
- GPU inference: 10-14 tok/s on 80B MoE models (Q3_K_M), 20+ tok/s on 27B dense (Q6/Q8)
- CPU inference: 15-25 tok/s on 4B models (Q4_K_M), always available, no GPU contention
- Enough VRAM for one large model at a time, swapped via Portainer API in ~30s

### What it does NOT get you
- Concurrent GPU models — one stack at a time, period
- Flash Attention — Pascal has no Tensor Cores; FA is 50% slower, not faster
- vLLM — compute capability 6.1 is too old
- Fast cold starts — GPU model loading takes 20-40s depending on size

### Key hardware findings (March 2026 — 2026-09 corrections inline)
- **Force MMQ kernels** (`GGML_CUDA_FORCE_MMQ=1`) — INT8 matmul is the optimal path for P40. **(Corrected 2026-09: on upstream llama.cpp the env var is dead code — MMQ is always selected on CC 6.1; the kernels were never off. MODEL_STACK_FINDINGS.md §3 / BACKEND_RESEARCH.md U5.)**
- **Row-split for dual GPU** (`-sm row -ts 24,24`) — 12-14 tok/s vs 7 tok/s for layer-split. **(Corrected 2026-09: `-sm row` was removed upstream 2026-07-06 (commit 74976e1ae); post-removal stacks run layer split and recover the throughput via `--parallel 4` + MTP speculative decoding. MODEL_STACK_FINDINGS.md §2 / BACKEND_RESEARCH.md U1.)**
- **Flash Attention OFF** (`-fa off`) — counterintuitive but measured; Pascal lacks the hardware. **(Corrected 2026-09: per-family now — the SSM+attention hybrid stacks deploy FA on, and llama.cpp requires it for quantized KV cache (-ctv q8_0), which is how qwen38 fits 262k context. MODEL_STACK_FINDINGS.md §4 / BACKEND_RESEARCH.md U7.)**
- **CPU threads for small models**: 4 threads saturates a Q4_K_M 4B model at ~20 tok/s; more threads adds diminishing returns and steals from GPU inference

## 3) The Tiered Architecture

### Tier 1: CPU (always-on, ~0-3s latency)
Two small Qwen3-4B models running on CPU via llama.cpp:
- **Classifier** (port 8091, 2 cores, 1GB): Single-label request triage (SIMPLE/RAG/CODE/REASON). Responds in 200-600ms warm.
- **Helper** (port 8092, 4 cores, 4GB): General-purpose — summaries, RAG, Q&A, quality gate fallback judge, tool matching. 15-25 tok/s.

These never compete with GPU inference. They survive GPU swaps, GPU crashes, and GPU power-off. They're the floor — the system always has *something* available.

### Tier 2: GPU (one model at a time, ~5-15s latency)
**Updated 2026-09:** the original four stacks grew to twelve, most with vision via mmproj. Current workhorse: Qwen3.8-27B dense Q6_K with 4 parallel slots + MTP speculative decoding (~13-17 t/s single, ~15 t/s concurrent). The March list (Qwen3.5 Q8/Q6, Qwen3-Next-80B, Qwen3-Coder-Next) is now the historical core; additions include Gemma 4 26B-A4B MoE (41 t/s fast path), Qwen3.6-35B/27B SSM+attention hybrids, and higher/lower quant variants of each.

Swapped automatically by the proxy based on model alias. 10-minute anti-flap cooldown. Rollback on failed swap.

### Tier 3: Cloud (always-on, ~10-15s latency, costs money)
**Updated 2026-09:** Z.AI GLM family via quality gate — now two real pools instead of a model list: `glm-5.3` (flagship, text-only, forced thinking, cap 6) and `glm-5.3-flash` (multimodal workhorse, 3x quota, cap 5). Every other id (glm-5.2, glm-4.7, glm-4.7-flash, glm-4.6v, glm-5-turbo) is a legacy alias the proxy reroutes onto one of those two pools — see §5 update below. glm-5.1 and glm-4.5-air were purged 2026-09-02 after Z.AI dropped them undocumented.

### Routing
A single proxy at port 4000 handles everything:
- Model aliases map to tiers (e.g., `auto` → classifier decides, `helper` → CPU, `reasoning` → GPU, `glm-5-turbo` → cloud)
- `auto-route` runs the classifier first, dispatches SIMPLE/RAG to CPU helper, CODE/REASON to GPU
- Clients see one endpoint with all models available

## 4) What We Learned About Small Models

### They're better than you think at narrow tasks
A 4B parameter model at Q4_K_M quantization can reliably:
- Classify request intent into 4-5 categories (>85% accuracy vs human labels)
- Match a user request to the correct tool from a list of 27 tool names
- Judge whether an LLM response is empty, truncated, or incoherent
- Summarize paragraphs and answer factual questions

### They fail predictably
A 4B model will NOT:
- Generate complex multi-step plans
- Write correct code for non-trivial tasks
- Handle nuanced judgment calls (e.g., "is this response *good enough*?")
- Follow complex rubrics with multiple criteria

The failure mode is consistent: they latch onto surface-level pattern matching and miss deeper reasoning. This is actually useful — you can design around it by keeping their tasks narrow.

### Prompt engineering matters more, not less
With a 4B model, every token in the prompt is a larger fraction of the context window and attention budget. Findings:
- **Names-only tool lists** (40 tokens) outperform described tool lists (200+ tokens) — the model makes the same decision faster with less noise
- **Single-label classification** with "reply with one word only" is far more reliable than structured output
- **Prompt caching** (llama.cpp's built-in KV cache) makes the system prompt essentially free after first request — only new tokens cost eval time
- **Temperature 0.0** is mandatory for classification tasks; any randomness introduces label drift

### CPU inference is the underrated tier
At 20 tok/s on 4 CPU cores, a 4B model handles most "glue" tasks faster than a GPU model handles complex ones. The latency budget for classification (200-600ms) and tool matching (2-3s) is invisible to the user compared to the 10-15s GPU or cloud round-trip that follows.

The counterintuitive finding: **adding small CPU models made the whole system faster**, not because they're fast in absolute terms, but because they prevent expensive work from happening when it isn't needed.

## 5) What We Learned About Cloud Integration

### The quality gate pattern
Cheap cloud models (Z.AI GLM family) are capable but unreliable in specific ways:
- They narrate actions instead of executing them ("I'll set that up for you" instead of calling the tool)
- They hallucinate tool requirements for simple factual questions
- They truncate responses under load

The solution is a quality gate — a pipeline between the client and the cloud model that:
1. Validates responses deterministically (tool call structure, required parameters)
2. Evaluates responses via an LLM judge (empty? truncated? incoherent? missing tool calls?)
3. Retries with structured feedback when validation fails

### The judge must have a rubric
The single most important finding: an LLM judge without specific criteria will hallucinate failures. Our initial judge prompt said "check if the response requires tool use" — a quantized MoE model interpreted this as "every response needs tools" and flagged simple factual answers as failures.

The fix was giving the judge:
- An explicit list of what tools exist (read from the request payload, not hardcoded)
- A 3-part criteria: user asked for ACTION + response has NO tool_use blocks + response narrates instead of acting
- Clear exclusions: knowledge questions, opinions, analysis, greetings are NEVER tool failures

### Pre-classification eliminates retries
The quality gate retry loop (3 attempts × 12s each = 36-45s) existed because cloud models narrate instead of calling tools. The breakthrough was having the local CPU model pre-classify the request:

1. Qwen helper (4B, CPU) sees the user request + available tool names
2. Returns which tool(s) apply, or NONE
3. If a tool matches, inject a structured nudge: "You MUST respond with a tool_use block for [tool_name]"
4. Cloud model sees the nudge and produces the tool call on first attempt

Result: 36-45s reduced to 15-20s for action requests. The CPU model spends 2-3s identifying the right tool, saving 12-24s of wasted cloud retries. Zero cost — the CPU model is local.

### Cloud models need structural prompting for structural output
Telling a cloud model "use your tools" doesn't work. The model's completion probability is already weighted toward chat-style responses. What works:
- **Name the specific tool**: "Use the cron tool" not "use your tools"
- **Frame as action, not conversation**: The nudge is injected as a second-to-last message so the user's actual request is what the model attends to last
- **Don't stack nudges on retry**: First attempt gets the pre-classification nudge. Retries get structured feedback naming the tool. Different strategy for each attempt.

### Concurrency caps are dynamic — and synthetic tests will lie to you
**(added 2026-09)** At first we treated each model's rate limit as a static number to discover once. The caps set from small synthetic requests on 2026-09-02 held up poorly; re-testing the same models at a different hour produced different numbers. The upstream limiter varies by load window, and the payload shape matters — small test requests are not what the gateway sends.

The method that produced trustworthy caps: **stress with real gateway-shaped payloads** (median ~32K tokens, sent from inside the network with real request bodies), record admission vs 429, and set the cap at worst-observed. Recorded worst-observed admission under real-payload stress (2026-09-02/03):
- glm-5.3: burst of 8 admitted **6**; 6 sustained ran 13/13 clean → cap 6
- glm-5.3-flash: morning window 429'd at 6; evening window admitted 8/8 → cap **5** (the lower, morning observation)
- glm-5-turbo: 8/8 burst clean, 6 sustained 9/9 clean, 429s at 12 → cap 8 (since superseded — see next lesson)

Treat every cap as a defense, not a promise: the limiter is dynamic, so the number is "worst we've observed," re-verifiable any time. Snapshots: `frozen-configs/20260902T025602Z_pre-concurrency-fix`, `frozen-configs/20260902T221523Z_pre-real-payload-limit-revision`.

### The model you request is not always the model that answers
**(added 2026-09-04)** This is the best debugging story of the batch. glm-5-turbo was stress-verified as its own pool on 2026-09-03: 8 concurrent, clean, its own cap. The next day, 3/3 production requests that sent `glm-5-turbo` verbatim upstream came back with `"model": "glm-5.3-flash"` in the response body. Z.AI had silently moved it onto the flash pool — the id still works, still bills, but the capacity behind it changed.

Why this matters more than it looks: if 5-turbo draws from the flash pool and you cap it at 8 while flash is capped at 5, your *real* concurrency on that pool is 13 — every cap you measured is fiction. **Account concurrency on the pool that serves the request, not the id the client sends.**

Implemented as a proxy-side routing map (`UPSTREAM_ROUTES` in config.py, enforced in code before caps/fallbacks/metrics key on the model; every reroute emits an `upstream_reroute` REQLOG event and an `X-Routed-Model` response header). Two design rules that emerged: (1) routing is never the client's job — clients keep whatever model id they're configured with; (2) the map lives in code, and the config-file keys that document it trigger a drift warning at load if they disagree — documentation that can't silently diverge from enforcement.

### Fallbacks must name their target
**(added 2026-09)** The local GPU fallback originally targeted "whatever stack is active." That serves the wrong model silently — a cloud request failing over gets whichever local model happens to be loaded, with nothing in the response naming the substitution. The fix pins the fallback model explicitly (`local_fallback_model: qwen38-dense`) and skips the fallback — logged — unless that exact stack is active. A fallback that might serve a *different* model than intended is worse than no fallback.

### Small protocol bugs kill fallbacks invisibly
**(added 2026-09)** Two production bugs found while making the fallback path actually work, both worth writing down:

1. **`HTTP/1.1 0`.** A transport-error path produced status 0, which Python's `send_response()` happily emitted as an invalid status line, breaking the client connection instead of returning an error. The fix clamps any out-of-range status to 502 at the send boundary. Lesson: validate at the protocol edge — exception paths produce exactly the values you didn't plan for.
2. **null-content 400s.** Anthropic-format tool-call assistant messages carry `content: null`; llama.cpp rejects null content alongside `tool_calls` with a 400. Every local GPU fallback failed this way — silently, because the fallback path never surfaced the backend's error detail. Fixes: the translator now emits `""` instead of null, and fallback errors return 502 *with the real backend detail attached*. Lesson: a fallback chain is only as good as its error propagation — "fallback failed" with no detail is undebuggable.

## 6) What We Learned About Operations

### Single-variable changes are non-negotiable
Every change is one thing, tested, then frozen. The freeze captures ALL stacks, not just what changed — because a "monitoring only" change that breaks a GPU stack's bind mount is invisible if you only froze monitoring.

Freeze process: tar + sha256sum every stack directory → timestamped directory under `frozen-configs/`. Restore is: verify checksums, extract, restart stacks. Total restore time: ~2 minutes.

### Portainer is the control plane, not Docker Compose
Docker Compose is for building images. Portainer owns the running state. Editing a local compose file does nothing to the running stack — you must push via Portainer API or recreate the stack. The Edit tool (and any file editor) creates new inodes, breaking Docker bind mounts.

**Update 2026-09: "always restart affected stacks" was wrong — restarts are not enough.** Verified in production: after a stop/start, the container kept serving the OLD code. Bind mounts and image layers both resolve at container **CREATE** time — a restart re-attaches the old inode and the old image layer, so `stop`/`start` silently serves pre-change code forever. The correct procedure is container **recreation**: rebuild the image if code changed (smart-proxy Python is baked into the image at build time; only `config.yaml` and `state.json` are bind-mounted), then a Portainer `PUT /api/stacks/{id}` redeploy — **preserving the stack's `Env`**, which holds the API keys. Then verify the change is live *inside the container* (`docker exec` grep, or observe the new behavior): a Portainer 200 means the PUT was accepted, not that the new code is serving. Two more hard-won details: the proxy loads config at startup only (no hot reload — every config change needs the redeploy), and never print the PUT response body — it echoes the API key values back into your terminal.

### Monitoring must survive what it monitors
Prometheus, Grafana, cAdvisor, and Node Exporter run in their own always-on stack, independent of GPU stacks. GPU swaps, GPU crashes, GPU power-off — monitoring keeps recording. This seems obvious but the original setup had monitoring embedded in GPU stacks, meaning every swap created a gap in metrics.

### Firewall ordering matters on Tailscale
UFW with a blanket DENY OUT on the Tailscale interface requires `ufw insert` (not `ufw allow out`) to add rules before the deny. `ufw allow out` appends after the deny and never matches. We caught this before it caused problems, but it would have been a silent failure — traffic blocked with no error message.

## 7) Cost Analysis

### Hardware (one-time)
| Component | Cost |
|-----------|------|
| EPYC 7302 + motherboard | ~$200 |
| 128 GB ECC DDR4 | ~$200 |
| 2x Tesla P40 | ~$300 |
| Case, PSU, NVMe | ~$200 |
| **Total** | **~$900** |

### Cloud (ongoing)
Z.AI GLM models are significantly cheaper than OpenAI/Anthropic equivalents. The quality gate adds 2-3 retries in worst case, but with the tool-nudge fix, most requests pass on first attempt.

### What the tiered architecture saves
- Heartbeats, status checks, tool results: handled by CPU helper (free) instead of cloud API (per-token cost)
- Simple Q&A, summaries, classification: CPU tier at 0 marginal cost
- Only complex reasoning and agent actions hit cloud — and they pass on first attempt instead of 3

## 8) What To Explore Next

### 8.1 Larger CPU models
The EPYC has 16 cores. We're using 6 (2 classifier + 4 helper). A Qwen3-8B at Q4_K_M on 6-8 cores could handle more complex classification and potentially replace the GPU judge entirely.

### 8.2 Persistent prompt caching
llama.cpp caches the KV state for repeated system prompts, but it's per-session. A shared prompt cache across requests for the classifier and helper would eliminate cold-start eval entirely.

### 8.3 Request logging for debugging
The quality gate builds conversation summaries and response summaries but doesn't persist them. Adding lightweight request/response logging (conversation summary + verdict, not full payloads) would make debugging agent behavior possible without reconstructing from scattered container logs.

**Done (2026-09):** REQLOG now emits structured per-request events (`msg_start`/`msg_end`/`traffic_cop`/`upstream_reroute`) keyed by req_id. It's how the 5-turbo pool merge was verified in production (reroute events visible in live traffic within minutes of deploy) and how reroute volume was counted (63 reroutes in a 30-minute window).

### 8.4 Adaptive timeout
The tool-match timeout is fixed at 4s. Under load (two OpenClaw instances), the helper queue backs up and timeouts increase. An adaptive timeout based on helper queue depth would let the system degrade gracefully rather than binary pass/timeout.

## 9) Summary

The thesis is simple: **most AI agent traffic doesn't need a frontier model**. A $600 server with two used datacenter GPUs and a pair of 4B CPU models can handle the majority of workload locally, routing only the hard problems to cheap cloud inference — and when it does route to cloud, a local model pre-classifies the request so the cloud model gets it right on the first try.

The key insight is that small models aren't replacing large ones. They're **steering** them. A 4B model that can say "this request needs the cron tool" in 2 seconds saves 30 seconds of a cloud model fumbling toward the same conclusion. The tiers aren't a hierarchy of quality — they're a division of labor.

---

## Appendix: Architecture Diagram

```
Clients (OpenClaw agents, OpenWebUI, curl)
    │
    ▼
Smart Proxy (port 4000) ─── single endpoint, all models
    │
    ├── CPU Tier (always-on, free)
    │   ├── Classifier (8091) ── request triage, 200-600ms
    │   └── Helper (8092) ───── Q&A, RAG, judge fallback, tool matching, 2-3s
    │
    ├── GPU Tier (one at a time, swapped on demand)
    │   ├── qwen35-opus-q8 ─── 27B reasoning
    │   ├── qwen35-opus-q6 ─── 27B long-context
    │   ├── qwen3-80b ──────── 80B MoE workhorse
    │   └── qwen3-coder ────── 80B MoE coding
    │
    ├── Cloud Tier (always-on, costs money)
    │   └── Z.AI GLM family ── via quality gate + tool nudge
    │
    ├── Embedding (8090) ───── nomic-embed, always-on CPU
    ├── Qdrant (6333) ──────── vector DB for RAG
    └── MCP Tools (8093/8095) ─ Qdrant search, system status

Quality Gate Pipeline (cloud tier only):
    Request → Qwen tool-match → inject nudge → Z.AI → judge → [retry if needed] → response
```

*(March snapshot — the GPU tier grew to twelve stacks by 2026-09; see CLAUDE.md for the current list and MODEL_STACK_FINDINGS.md for the full fleet table with measured throughputs.)*
