# Local Agent Ecosystem — Implementation Plan

**Date:** 2026-03-27
**Scope:** LLM Box (llm-box.lan) + NUC (coder-host.lan) + all clients (OpenWebUI, OpenClaw, API consumers)
**Method:** Per ITERATE_AND_FREEZE_PLAYBOOK.md — single-variable changes, gated promotion, freeze after each milestone

---

## Current Friction Points

### 1. GPU swap tax on every request type
Every request that doesn't match the currently-loaded stack either gets a 503 or triggers a ~2-minute swap + 10-minute cooldown. A user asking "what time is the meeting?" and a user asking "analyze this 40-page contract" both require the same GPU model. There is no lightweight inference tier — every request pays the full cost.

### 2. Inference serialization bottleneck
The proxy's `inference_lock` allows only 1 request at a time on the GPU, with up to 3 queued. The 4th gets a 503. During an OpenClaw agent burst (manager delegates to 3 specialists simultaneously), two requests queue and the third is rejected — even if the tasks are trivial.

### 3. Quality gate has no fallback judge during swap
The quality gate's LLM judge calls `localhost:4000/v1/chat/completions`, which hits the GPU model. During a swap, the judge can't run and defaults to PASS — meaning malformed GLM responses slip through during the exact window the system is most vulnerable.

### 4. OpenClaw agents are model-unaware
Every `sessions_spawn` goes through the same model regardless of task complexity. The homelab agent checking "is the server up?" uses the same 27B reasoning model as the assistant drafting a multi-page document. No signal from agents to the proxy about task weight.

### 5. No always-on RAG path
Qdrant is running. Embeddings are running. But no model can query Qdrant and synthesize an answer without a GPU stack loaded. RAG is only available when a GPU model happens to be active.

### 6. Swap cooldown blocks legitimate work
After the workhorse finishes a task and you need the coder, you wait 10 minutes. The cooldown protects against flap but doesn't distinguish between genuine task switches and flap loops.

---

## What This Setup Relieves

| Friction Point | How It's Relieved |
|---|---|
| GPU swap for simple requests | Classifier + helper handle 60-70% of traffic on CPU — no swap needed |
| Inference queue rejection | Simple requests never hit the GPU queue — only complex work competes for the lock |
| No judge during swap | Helper (4B) acts as backup judge — quality gate never defaults to blind PASS |
| Agents all use same model | Proxy routes by classified intent — simple→helper, complex→GPU, code→remote |
| No always-on RAG | Helper + Qdrant = always-available RAG, independent of GPU state |
| Cooldown blocks work | Fewer swaps overall means cooldown triggers less often |

---

## New Functionality (Not Possible Today)

- **`auto`/`smart` alias** — clients don't choose a model; the classifier picks the right tier per request
- **Always-on RAG** — knowledge retrieval works 24/7 regardless of which GPU stack is loaded (or if none is)
- **Backup quality gate judge** — Z.AI responses are always evaluated, even mid-swap
- **MCP tool access** — models can directly invoke Qdrant search, check GPU status, read files mid-generation
- **Agent-aware routing** — OpenClaw agents can hint task complexity; proxy routes accordingly
- **Tiered agent responses** — simple tasks get sub-second answers from the 4B model; complex tasks get the full reasoning model
- **Ecosystem observability** — Grafana dashboard shows traffic split, swap avoidance rate, tool usage across all tiers

---

## CPU Contention Analysis: Impact on GPU Inference

**Will the new CPU models hurt GPU model performance?** No. Here's why.

### What the CPU does during GPU inference

The GPU stacks set `THREADS=32` (full EPYC 7302) but have **no Docker CPU limits**. However, during active inference those threads are mostly idle:

- **Token generation** (95%+ of inference time): The CPU schedules CUDA kernels, manages KV cache pointers, and tokenizes/detokenizes. The actual compute is entirely on the P40s. CPU threads spend most cycles parked, waiting on CUDA calls.
- **Prompt processing** (brief burst at start of each request): CPU is more active here — tokenization, position encoding assembly, dispatch. But with AVX2 disabled in the ik_llama.cpp-gpu fork (see below), this work is single-threaded and lightweight.
- **Row-split synchronization**: PCIe transfers between GPUs are handled asynchronously by the NVIDIA driver, not by CPU threads.

GPU utilization during inference is 66-70% — the bottleneck is GPU compute, not CPU.

### Why AVX2 is off (and stays off)

AVX2 was investigated and is a dead end for this hardware:
- The ik_llama.cpp-gpu fork (which supports row-split on Pascal) has AVX2 disabled by design
- The newer ik_llama.cpp fork requires AVX2 but **removed row-split mode** — its replacement (graph-split) crashes on Pascal GPUs
- Per `qwen3.5/BACKEND_RESEARCH.md`: *"The original ik_llama.cpp-gpu binary is OPTIMAL for this hardware. Do NOT switch to the new ik_llama.cpp fork."*
- Since AVX2 is off, the CPU does even less work during inference than it would with SIMD enabled — more headroom for the new models.

### Resource isolation

The proposed CPU models are small and constrained:

| Service | CPU Threads | Duty Cycle | Notes |
|---------|-------------|------------|-------|
| Classifier (0.6B) | 2 | Bursty — one-word output in ~50ms, then idle | Only active during classification |
| Helper (4B) | 4 | Intermittent — ~20 tok/s when active | Only active when handling routed requests |
| GPU model | 32 (claimed) | Low actual CPU usage during generation | Threads mostly parked waiting on CUDA |

**Worst case:** A 4000-token prompt hits the GPU model (brief CPU spike for tokenization) while the helper is mid-generation on a separate request. The helper's 4 threads and the GPU model's brief CPU burst can coexist on 16 physical cores without contention — the GPU model's threads aren't doing sustained CPU work, they're waiting on PCIe round-trips.

### Recommended safeguard

Add explicit `cpus` limits to the new containers to guarantee isolation:

```yaml
# Classifier container
cpus: "2"

# Helper container
cpus: "4"
```

The embedding agent already does this (`cpus: "4"`). This ensures the kernel scheduler can't over-allocate even in pathological scenarios, while still leaving 26+ threads available to the GPU model container (far more than it actually uses).

---

## Target Architecture

```
Clients (OpenWebUI, API, Telegram, Discord)
  │
  ▼
Smart Proxy (port 4000) ─── routing by alias + intent classification
  │
  ├─► Classifier (port 8091) ── NEW: Qwen3-0.6B Q8, CPU, always-on
  │     Purpose: intent routing, request triage, quick yes/no decisions
  │     ~500MB RAM, 2 threads, ~86 tok/s
  │
  ├─► Helper Agent (port 8092) ── NEW: Qwen3-4B Q4_K_M, CPU, always-on
  │     Purpose: summarization, RAG retrieval, tool validation, simple Q&A
  │     MCP clients: Qdrant, filesystem
  │     ~3GB RAM, 4 threads, ~20 tok/s
  │
  ├─► GPU Model (port 8080) ── existing, swappable via Portainer
  │     reasoning / longctx / workhorse / coder stacks
  │
  ├─► Embedding (port 8090) ── existing, CPU, always-on
  │     nomic-embed-text-v1.5
  │
  ├─► Remote Coder (NUC:1234) ── existing, always-on
  │     Qwen3-Coder-30B on LM Studio
  │
  ├─► Qdrant (port 6333) ── existing, always-on
  │
  └─► Z.AI GLM-5/Turbo ── existing, quality-gated
        OpenClaw orchestrator on NUC delegates via sessions_spawn

OpenClaw (NUC) ─── orchestrator
  │
  ├─► manager agent ─── reads, delegates, never executes
  ├─► assistant agent ─► helper (8092) for simple tasks, GPU for complex
  ├─► homelab agent ─► helper (8092) for status checks, GPU for analysis
  ├─► church / aquatics / gardeners agents ─► helper for routine, GPU for drafting
  │
  └─► quality gate catches malformed tool calls (deterministic rules, deployed today)
```

---

## Resource Budget

| Service | CPU Threads | RAM | GPU VRAM | Port | Status |
|---------|-------------|-----|----------|------|--------|
| Smart Proxy | 2 | 512MB | — | 4000 | Existing |
| Embedding Agent | 4 | 8GB | — | 8090 | Existing |
| Qdrant | 4 | 8GB | — | 6333 | Existing |
| Monitoring stack | ~2 | ~2GB | — | 9090/3000/8081/9100 | Existing |
| **Classifier (NEW)** | **2** | **~500MB** | — | **8091** | Planned |
| **Helper Agent (NEW)** | **4** | **~3GB** | — | **8092** | Planned |
| GPU Model Stack | 32 | varies | 29-39GB | 8080 | Existing |
| **Totals** | **~18 always-on** | **~22GB always-on** | 0 always-on | — | — |

**Remaining headroom after all services:** ~14 threads, ~106GB RAM — plenty of margin.

---

## Phase 1: CPU Classifier Model (Qwen3-0.6B)

**What:** Deploy Qwen3-0.6B Q8_0 as an always-on CPU inference service on port 8091.

**Single variable changed:** New container on unused port with unused CPU/RAM. No existing services touched.

### Ecosystem Benefits

**LLM Box (Smart Proxy):**
- Pre-classify requests before routing — determine if the query needs the GPU model or can be handled by the helper (Phase 2) or a simple canned response
- Reduce unnecessary GPU swaps by catching requests that don't need heavy inference
- Use as a fast judge replacement for simple quality gate checks (supplement the current LLM judge at ~86 tok/s vs ~10 tok/s on GPU)

**NUC (OpenClaw):**
- Agents get a sub-100ms classification endpoint for intent detection
- Manager agent can triage incoming user messages before deciding which specialist to dispatch
- Always available — no swap wait, no cooldown, no 503s

**Clients (OpenWebUI / API consumers):**
- Faster initial response for simple queries ("what time is the meeting", "is the server up")
- Model alias `classify` or `triage` available in model picker for explicit lightweight use
- No swap triggered for quick lookups

### Implementation Steps

1. Download Qwen3-0.6B Q8_0 GGUF to `~/models/`
2. Create `~/llm-hosts/classifier-agent/` directory
3. Write `docker-compose.yml` — CPU-only llama.cpp server, port 8091, 2 threads, 1GB mem_limit
4. Write `.env` with model path, thread count, port
5. Deploy as Portainer stack
6. Add to `smart-proxy/config.yaml`:
   ```yaml
   backends:
     classifier:
       url: "http://localhost:8091"
       health: "/health"
   models:
     classifier:
       backend: "classifier"
       aliases: ["classify", "triage", "quick"]
       always_available: true
       description: "Qwen3-0.6B Q8 — fast classification, always-on"
   ```
7. Rebuild and redeploy smart-proxy

### Gate Criteria

- Health endpoint responds < 100ms
- Classification accuracy on 20 test prompts ≥ 90% (can it correctly label: needs-gpu, needs-rag, simple-answer, needs-code)
- No impact on existing GPU model throughput (measure before/after)
- OpenWebUI can select and use the model

### Freeze

Snapshot classifier-agent/ config + updated smart-proxy config after gate pass.

---

## Phase 2: CPU Helper Agent (Qwen3-4B + MCP)

**What:** Deploy Qwen3-4B Q4_K_M as an always-on CPU inference service on port 8092, with MCP connections to Qdrant and the local filesystem.

**Single variable changed:** New container on unused port. Depends on Phase 1 being stable but doesn't modify it.

### Ecosystem Benefits

**LLM Box (Smart Proxy / RAG Pipeline):**
- Always-on RAG endpoint — queries Qdrant embeddings and synthesizes answers without loading a GPU model
- Handles summarization requests (meeting notes, log digests) at ~20 tok/s with zero GPU contention
- Acts as a tool-use validation layer — can verify that tool calls have correct parameters before forwarding (supplements the deterministic checks we deployed today)
- Serves as a backup judge for the quality gate — if the active GPU model is mid-swap, the helper can evaluate Z.AI responses instead of defaulting to PASS

**NUC (OpenClaw):**
- Specialist agents get a dedicated always-on model for routine tasks:
  - `homelab` agent: quick system status checks, log parsing, alert triage
  - `church` / `aquatics` / `gardeners`: calendar lookups, FAQ answers, template-based responses
  - `assistant`: simple Q&A, reminders, note-taking
- Reduces latency for 60-70% of agent tasks that don't need reasoning-class models
- The 4B model with MCP can directly query Qdrant — agents get RAG answers without a multi-hop relay through the GPU model
- `sessions_spawn` calls from the manager can target the helper for simple delegations, reserving GPU for complex work

**Clients (OpenWebUI / API consumers):**
- New aliases `helper`, `rag`, `summarize` in model picker — instant responses for knowledge retrieval
- OpenWebUI users can ask questions about stored documents (via Qdrant) without triggering a GPU swap
- API consumers get a guaranteed-available endpoint for lightweight automation (scripts, cron jobs, webhooks)

**Monitoring (Grafana):**
- New Prometheus metrics from the helper's `/metrics` endpoint
- Track: helper request volume, latency, tok/s — gives visibility into what fraction of traffic is lightweight
- Helps inform future model sizing decisions

### Implementation Steps

1. Download Qwen3-4B Q4_K_M GGUF to `~/models/`
2. Create `~/llm-hosts/helper-agent/` directory
3. Write `docker-compose.yml` — CPU-only llama.cpp server, port 8092, 4 threads, 4GB mem_limit
4. Configure MCP connections (if llama.cpp MCP is available in the ik_llama.cpp-gpu fork; otherwise use a thin Python wrapper that calls Qdrant directly)
5. Write `.env` with model path, thread count, port, Qdrant endpoint
6. Deploy as Portainer stack
7. Add to `smart-proxy/config.yaml`:
   ```yaml
   backends:
     helper:
       url: "http://localhost:8092"
       health: "/health"
   models:
     helper:
       backend: "helper"
       aliases: ["helper", "rag", "summarize", "quick-answer"]
       always_available: true
       description: "Qwen3-4B Q4_K_M — RAG, summaries, tool validation, always-on"
   ```
8. Rebuild and redeploy smart-proxy
9. Add Prometheus scrape target for port 8092

### Gate Criteria

- Health endpoint responds < 200ms
- RAG retrieval: given a test document in Qdrant, correctly answers 5 factual questions
- Summarization: produces coherent 2-3 sentence summaries for 5 test inputs
- Tool-call validation: correctly identifies malformed tool calls in 10 test payloads
- Throughput: ≥ 15 tok/s sustained on CPU
- No impact on existing services (embedding throughput, GPU model throughput)
- OpenWebUI can select and use the model

### Freeze

Snapshot helper-agent/ config + updated smart-proxy config + Prometheus scrape config.

---

## Phase 3: Smart Routing (Classifier → Helper/GPU)

**What:** Update the smart proxy to optionally auto-route requests through the classifier before dispatching to helper or GPU, based on the classifier's judgment.

**Single variable changed:** Routing logic in proxy.py. No new containers.

### Ecosystem Benefits

**LLM Box (Smart Proxy):**
- Intelligent request triage without client involvement — any request to the default model gets classified first
- Requests classified as "simple" route to the helper (port 8092) — zero GPU involvement
- Requests classified as "complex" or "reasoning" route to the GPU model as before
- Requests classified as "code" route to GPU coder stack or remote coder
- Net effect: **fewer GPU swaps, faster median response time, lower GPU idle power**

**NUC (OpenClaw):**
- OpenClaw agents can send requests to a single alias (`auto` or `smart`) and let the proxy decide the right backend
- Manager agent doesn't need its own routing logic — the proxy handles model selection
- Reduces agent prompt complexity: agents focus on task content, not model selection
- Fallback: if helper can't handle a classified-as-simple request (low confidence output), the proxy can escalate to GPU

**Clients (OpenWebUI / API consumers):**
- New `auto` or `smart` alias that picks the fastest capable model for each request
- Power users still have explicit aliases (`reasoning`, `coder`, `helper`) for direct targeting
- Typical conversation: first message might go to GPU (complex), follow-ups ("ok thanks", "summarize that") go to helper
- Perceived latency drops significantly for mixed-complexity conversations

**Monitoring:**
- New proxy metrics: `requests_classified_simple`, `requests_classified_complex`, `requests_escalated`
- Grafana dashboard shows traffic split — helps tune classification thresholds
- Visibility into swap-avoidance rate (how many GPU swaps were prevented by routing to helper)

### Implementation Steps

1. Define classification prompt template (system prompt for the 0.6B classifier):
   ```
   Classify this request. Reply with one word only:
   SIMPLE — factual lookup, status check, short answer, FAQ
   RAG — needs document/knowledge retrieval
   REASON — needs multi-step reasoning, analysis, long-form writing
   CODE — needs code generation or debugging
   ```
2. Add `_classify_request()` method to proxy.py that calls classifier on port 8091
3. Add `auto-route` model entry in config.yaml:
   ```yaml
   auto-route:
     aliases: ["auto", "smart"]
     always_available: true
     description: "Auto-routes via classifier to helper or GPU"
   ```
4. Wire classification into `_handle_chat_completions` for the `auto-route` model
5. Add classification timeout (500ms) — if classifier doesn't respond, fall through to GPU model
6. Rebuild and redeploy smart-proxy

### Gate Criteria

- Classification adds < 500ms to request latency (p99)
- Correct routing on 30 test prompts: ≥ 85% agreement with human labels
- No regressions on existing direct-alias routing
- Escalation path works: helper timeout → GPU fallback
- OpenWebUI works with `auto` model alias

### Freeze

Snapshot updated smart-proxy + classification prompt template.

---

## Phase 4: MCP Tool Integration

**What:** Enable MCP tool servers for Qdrant, filesystem access, and system monitoring — accessible to both the helper agent and GPU models.

**Single variable changed:** MCP server containers + config. No changes to inference models.

### Ecosystem Benefits

**LLM Box (All Models):**
- Models can directly invoke tools mid-generation — no external orchestration needed
- Qdrant MCP server: semantic search over stored documents, chat history, knowledge base
- Filesystem MCP server: read/write files in designated directories (e.g., `~/llm-hosts/` for config inspection)
- System MCP server: query `nvidia-smi`, `docker ps`, disk usage — the model can answer "how are the GPUs doing?" by checking itself

**NUC (OpenClaw):**
- Specialist agents gain tool access they didn't have before:
  - `homelab` agent can query GPU status, container health, disk usage via MCP through the proxy
  - `assistant` agent can search the knowledge base (Qdrant) directly instead of requiring a multi-step RAG pipeline
  - All agents benefit from the proxy's tool-access layer — tools are centralized on the LLM box, not duplicated per agent
- The manager agent's delegation becomes richer: "delegate to homelab with tools: system-status, container-list"

**Clients (OpenWebUI):**
- OpenWebUI users can ask questions that require tool use ("what's in my notes about X?", "check if the proxy is healthy") and get tool-augmented responses
- Tool results appear inline in the response — transparent to the user

**Monitoring:**
- MCP servers expose their own health endpoints — add to Prometheus
- Track tool invocation frequency, latency, error rate
- Identify which tools agents use most — informs what to build next

### Implementation Steps

1. Deploy Qdrant MCP server container (Python, uses `qdrant-client` + `fastmcp`):
   - Exposes: `search(query, collection, top_k)`, `list_collections()`, `upsert(text, metadata, collection)`
   - Connects to Qdrant at `localhost:6333`
   - Port 8093 (HTTP transport)
2. Deploy filesystem MCP server container:
   - Scoped to read-only on `~/llm-hosts/` and `~/models/`
   - Exposes: `read_file(path)`, `list_dir(path)`, `search_files(pattern)`
   - Port 8094
3. Deploy system-status MCP server container:
   - Exposes: `gpu_status()` (nvidia-smi), `containers()` (docker ps), `disk_usage()`, `proxy_health()`
   - Port 8095
4. Configure helper-agent (8092) and GPU model stacks to connect to MCP servers
5. Update smart-proxy config with MCP server health endpoints for monitoring
6. Add Prometheus scrape targets

### Gate Criteria

- Each MCP server responds to tool calls within 1s
- Helper agent correctly uses Qdrant search tool on 5 test queries
- GPU model correctly uses system-status tool on 3 test queries
- No impact on inference latency when tools are not invoked
- MCP servers stay under 500MB RAM combined

### Freeze

Snapshot all MCP server configs + updated model configs + Prometheus scrape config.

---

## Phase 5: OpenClaw Agent Expansion

**What:** Configure new OpenClaw sub-agents on the NUC that target the new infrastructure — classifier, helper, MCP tools.

**Single variable changed:** OpenClaw agent configuration on the NUC. No LLM box changes.

### Ecosystem Benefits

**NUC (OpenClaw) — Primary beneficiary:**
- New agent routing strategy per specialist:
  - Simple/FAQ → helper (8092) — instant, always-on
  - Knowledge retrieval → helper + Qdrant MCP — sub-5s RAG answers
  - Complex reasoning → GPU model via proxy — full power when needed
  - Code → remote coder (NUC:1234) or GPU coder stack — depends on task
- Manager agent gets a `triage` tool: call classifier (8091) to determine optimal routing before dispatching
- Net effect: **agents are faster, cheaper, and more reliable because they're not all fighting over one GPU model**

**LLM Box:**
- GPU swaps drop significantly — majority of agent traffic stays on CPU tier
- GPU models reserved for the work they're actually needed for
- Better GPU utilization: fewer cold starts, longer sustained inference runs

**Clients:**
- Faster agent responses in Telegram/Discord/web channels connected to OpenClaw
- Users experience consistent latency instead of unpredictable 2-minute swap delays
- Agent-generated content quality improves: simple tasks get fast simple answers, complex tasks get full reasoning model treatment

### Implementation Steps

1. Update OpenClaw provider config to include new endpoints:
   ```json
   "helper": {
     "baseUrl": "http://agent-host.tailnet:4000",
     "api": "openai-chat",
     "models": [{"id": "helper"}, {"id": "classifier"}]
   }
   ```
2. Update each specialist agent's routing preferences:
   - Default model: `helper` (fast, always-on)
   - Escalation model: `workhorse` or `reasoning` (when helper confidence is low)
   - Code model: `remote` or `coder` (depending on task complexity)
3. Update manager agent's delegation logic to include model hints in `sessions_spawn` calls
4. Test each agent end-to-end through a representative task set
5. Deploy updated OpenClaw config on NUC

### Gate Criteria

- Each specialist agent completes its representative task set within expected latency
- No regressions on existing agent functionality
- GPU swap rate drops by ≥ 30% compared to pre-Phase-5 baseline
- Agent response latency p50 drops by ≥ 40% (due to helper handling simple requests)

### Freeze

Snapshot OpenClaw config on NUC + document the routing strategy per agent.

---

## Phase 6: Observability Dashboard

**What:** Build a Grafana dashboard that visualizes the full agent ecosystem — request flow, model utilization, swap frequency, tool usage, agent activity.

**Single variable changed:** Grafana config only. No inference changes.

### Ecosystem Benefits

**Across everything:**
- Single pane of glass showing: which models are handling what traffic, how often GPUs swap, which agents are most active, which MCP tools get used
- Capacity planning: see when CPU models are saturated and need scaling
- Alert on: helper model degraded throughput, MCP server down, swap failure, quality gate rejection spike

### Panels

1. **Request Flow** — requests/min by destination (GPU, helper, classifier, remote, Z.AI)
2. **GPU Swap Activity** — swaps/hour, cooldown time remaining, active stack
3. **Model Throughput** — tok/s per model (GPU, helper, classifier, embedding)
4. **Quality Gate** — pass/fail/retry rate, deterministic vs LLM judge catches
5. **MCP Tool Usage** — invocations/min by tool, latency distribution
6. **Agent Activity** — requests by OpenClaw agent (if tagged in headers)
7. **Resource Utilization** — CPU, RAM, VRAM per service

---

## Summary: Ecosystem Impact by Consumer

| Consumer | Before | After |
|----------|--------|-------|
| **OpenWebUI users** | Every request hits GPU or waits for swap | Simple queries instant (helper), complex queries still use GPU. `auto` alias handles routing. |
| **OpenClaw agents** | All agent requests compete for one GPU model, frequent 503s during swaps | Routine work on always-on helper, GPU reserved for reasoning. Agents faster and more reliable. |
| **API consumers** | Must know which alias to use, risk triggering unwanted swaps | `auto` alias routes intelligently. Helper always available for scripts/cron. |
| **Smart Proxy** | Routes to GPU or returns 503 | Routes to fastest capable model. Fewer swaps. Quality gate has backup judge. |
| **Monitoring** | GPU + container metrics only | Full visibility: model throughput, agent traffic, tool usage, classification split, swap avoidance rate. |
| **GPU models** | Loaded/unloaded frequently for mixed-complexity traffic | Reserved for complex work. Longer sustained runs. Better utilization. |
| **NUC** | Runs OpenClaw + LM Studio, under-utilized | Orchestrates smarter delegations, agents have tiered model access, fewer failures from malformed tool calls. |

---

## Implementation Order & Dependencies

```
Phase 1: Classifier ──────────────────────► freeze
                                               │
Phase 2: Helper Agent ─────────────────────► freeze
                                               │
Phase 3: Smart Routing (needs 1+2) ────────► freeze
                                               │
Phase 4: MCP Tools (needs 2) ──────────────► freeze
                                               │
Phase 5: OpenClaw Expansion (needs 1-4) ───► freeze
                                               │
Phase 6: Observability (independent) ──────► freeze
```

Phases 1 and 2 can be done in rapid succession (different ports, no overlap).
Phase 6 can be done in parallel with any other phase.
Each phase is independently rollbackable.
