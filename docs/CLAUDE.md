# CLAUDE.md

> **Portfolio note:** This is the actual operating manual the on-box coding agent works
> under, lightly sanitized (internal stack ids, plan details, and addresses removed).
> The HARD RULES and their failure notes are real lessons from real incidents. It is
> published as evidence of how this system is governed, not as a setup guide.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A self-hosted LLM inference stack on a single server (llm-box.lan) with dual NVIDIA Tesla P40 GPUs (24GB each = 48GB), AMD EPYC 7302 CPU (16c/32t), and 128GB RAM. Models run as Portainer stacks — one GPU stack at a time, swapped via a smart routing proxy.

## Architecture Overview

```
Clients / OpenWebUI
    → Smart Proxy (port 4000) — routes by model alias, auto-swaps Portainer stacks
        → GPU Model Stack (port 8080) — one active at a time via Portainer
        → Embedding Agent (port 8090) — CPU-only, always on
        → Remote Coder (coder-host.lan:1234) — always on
        → Qdrant (port 6333) — CPU-only vector DB for RAG
    → Monitoring (always-on, independent of GPU swaps)
        → Prometheus (9090), Grafana (3000), cAdvisor (8081), Node Exporter (9100)
```

### GPU Model Stacks (mutually exclusive — only one runs at a time)

Current active stack is tracked in `smart-proxy/state.json`.

| Stack Directory | Model | VRAM | Context | Purpose |
|-----------------|-------|------|---------|---------|
| `qwen38-dense-q6/` ← **active** | Qwen3.8-27B dense Q6_K (+ vision via mmproj) | ~23GB | 262k | Dense quality variant; 4 parallel slots + MTP spec decode (~13-17 t/s single, ~15 t/s concurrent) |
| `gemma4-moe-q8/` | Gemma 4 26B-A4B MoE Q8_0 (+ vision via mmproj) | ~29GB | 64k | Fast reasoning workhorse, 41 t/s |
| `qwen36-moe-q5/` | Qwen3.6-35B-A3B MoE UD-Q5_K_M (+ vision via mmproj) | ~25GB | 64k | Next-gen MoE workhorse (SSM+attention hybrid) |
| `qwen36-dense-q6/` | Qwen3.6-27B dense Q6_K (+ vision via mmproj) | ~21GB | 64k | Dense quality variant (SSM+attention hybrid) |
| `gemma4-moe-q6/` | Gemma 4 26B-A4B MoE Q6_K | ~22GB | 64k | Lower-VRAM Gemma MoE variant |
| `gemma4-dense-q8/` | Gemma 4 31B dense Q8_0 | ~34GB | 64k | Higher-quality dense Gemma |
| `gemma4-dense-q6/` | Gemma 4 31B dense Q6_K | ~26GB | 64k | Dense Gemma, long-context variant |
| `qwen35-opus-q8/` | Qwen3.5-27B Opus-distilled Q8_0 | ~29GB | 16k | Max-quality reasoning (Qwen line) |
| `qwen35-opus-q6/` | Qwen3.5-27B Opus-distilled Q6_K | ~22GB | 49k | Long-context Qwen reasoning |
| `qwen3-next-instruct/` | Qwen3-Next-80B-A3B Q3_K_M | ~39GB | 98k | 80B general workhorse |
| `qwen3-quantized-moe/` | Qwen3-Coder-Next Q3_K_M | ~39GB | 16k | Coding specialist |
| `deeply-tuned/` (frozen) | Qwen3-32B-Q6_K | ~29GB | 16k | Legacy baseline — do not modify |

Experimental stack directories not yet wired into smart-proxy: `qwen3.5/` (alternate Qwen3.5-27B build), `qwen3-next-instruct-vllm/` (vLLM experiment — not viable on P40 per `BACKEND_RESEARCH.md`).

### Always-On Services

| Directory | Port | Portainer Stack | Purpose |
|-----------|------|-----------------|---------|
| `smart-proxy/` | 4000 | smart-proxy  | Routing proxy + auto-swap via Portainer API |
| `smart-proxy/` (Qdrant) | 6333/6334 | smart-proxy  | Vector DB for RAG |
| `embedding-agent/` | 8090 | embedding-agent  | Nomic Embed Text v1.5 (CPU-only) |
| `monitoring/` | 9090, 3000, 8081, 9100 | monitoring  | Prometheus, Grafana, cAdvisor, Node Exporter |
| `classifier-agent/` | 8091 | classifier-agent  | Qwen3-4B-Instruct-2507 Q4_K_M — classification + triage (CPU-only) |
| `helper-agent/` | 8092 | helper-agent  | Qwen3-4B Q4_K_M — summarization, RAG, quality gate fallback (CPU-only) |
| `mcp-servers/` | 8093 | mcp-servers  | Qdrant MCP — vector search, collection mgmt, document upsert |
| `mcp-servers/` | 8095 | mcp-servers  | System MCP — GPU status, containers, disk usage, proxy health |
| `tool-match-agent/` | 8094 | tool-match-agent  | Qwen3-4B Q4_K_M — dedicated quality-gate tool matching + judge fallback (CPU-only, 8 threads, --parallel 4) |

## Key Directories

- `smart-proxy/` — Routing proxy (Python stdlib) + Qdrant. Uses Portainer API to swap GPU stacks.
- `monitoring/` — Unified monitoring stack (Prometheus, Grafana, cAdvisor, Node Exporter). Always-on, survives GPU swaps.
- `classifier-agent/` — Qwen3-4B-Instruct-2507 Q4_K_M classifier (CPU-only, port 8091)
- `helper-agent/` — Qwen3-4B Q4_K_M helper/summarizer (CPU-only, port 8092). Quality gate fallback judge.
- `mcp-servers/` — MCP tool servers: qdrant-mcp (8093) for vector search, system-mcp (8095) for GPU/container/disk status.
- `gemma4-moe-q8/`, `gemma4-moe-q6/` — Gemma 4 26B-A4B MoE stacks (MoE, vision-capable via mmproj)
- `qwen38-dense-q6/` — Qwen3.8-27B dense stack (own llama.cpp clone @ b94041a98, layer split, --parallel 4, vision via mmproj)
- `qwen36-moe-q5/` — Qwen3.6-35B-A3B MoE stack (SSM+attention hybrid, vision-capable via mmproj)
- `qwen36-dense-q6/` — Qwen3.6-27B dense stack (SSM+attention hybrid, vision-capable via mmproj)
- `gemma4-dense-q8/`, `gemma4-dense-q6/` — Gemma 4 31B dense stacks
- `qwen35-opus-q8/`, `qwen35-opus-q6/` — Opus-distilled 27B reasoning stacks (Jackrong v2)
- `qwen3-next-instruct/` — 80B MoE workhorse stack
- `qwen3-quantized-moe/` — Coder MoE stack
- `deeply-tuned/` — **FROZEN** legacy baseline. Do not modify.
- `ik_llama.cpp-gpu/` — Forked llama.cpp with CUDA optimizations for P40
- `embedding-agent/` — CPU-only embedding service
- `frozen-configs/` — Timestamped snapshots of known-good configs

## Smart Proxy

The proxy at port 4000 routes by model alias and auto-swaps Portainer stacks:

```bash
# GPU model aliases → stacks (mutually exclusive, swap via Portainer)
qwen38, qwen3.8, qwen38-dense, dense, quality → qwen38-dense-q6 (currently active)
gemma, gemma4, gemma-moe       → gemma4-moe-q8
qwen36, qwen3.6, qwen-moe, next → qwen36-moe-q5
qwen36-dense, qwen3.6-dense    → qwen36-dense-q6
reasoning, precise, quality    → qwen35-opus-q8
longctx, deep-reason, research → qwen35-opus-q6
workhorse, general, execute    → qwen3-next-instruct
coder, code, dev               → qwen3-a3b (dir: qwen3-quantized-moe/)

# Always-on routing
auto, smart                    → auto-route (classifies → SIMPLE/RAG to helper, CODE/REASON to active GPU)
classify, triage, quick        → classifier-agent (always available, CPU)
helper, rag, summarize, quick-answer → helper-agent (always available, CPU)
embed, nomic-embed-text        → embedding agent (always available)
remote, lmstudio               → remote coder (always available)

# Cloud tier (Z.AI GLM family) via quality gate — /v1/messages endpoint only
glm5, glm-5, glm5.3, glm53     → glm-5.3 (flagship since 2026-08-18; text-only, forced thinking. 6 concurrent — worst-observed admission under real-payload stress; frontier_fallback → glm-5.3-flash)
glm53flash, glm5.3-flash       → glm-5.3-flash (multimodal vision workhorse, higher quota pool, 5 concurrent — worst-observed; no frontier fallback, local GPU catches)
glm5.2, glm52                  → glm-5.2 (legacy explicit-only; proxy reroutes to glm-5.3 via UPSTREAM_ROUTES — enforced 2026-09-04; effective cap 6)
glm5-turbo                     → glm-5-turbo (undocumented legacy id, verified still served 2026-09; proxy reroutes to glm-5.3-flash via UPSTREAM_ROUTES — enforced 2026-09-04: Z.AI began serving it from the flash pool, 3/3 verified; effective cap 5)
glm-4-7, glm47                 → glm-4.7 (proxy reroutes to glm-5.3-flash via UPSTREAM_ROUTES — enforced 2026-09-04; effective cap 5)
glm-4-7-flash, glm47flash      → glm-4.7-flash (proxy reroutes to glm-5.3-flash via UPSTREAM_ROUTES — enforced 2026-09-04; no frontier fallback; 529-overloaded upstream 2026-09-02 predates the reroute)
glm-4-6v, glm46v               → glm-4.6v (proxy reroutes to glm-5.3-flash via UPSTREAM_ROUTES — enforced 2026-09-04; vision alias preserved)
# Upstream routing is ENFORCED PROXY-SIDE (config.py UPSTREAM_ROUTES, applied in proxy.py after alias resolution; 2026-09-04) — never client-side. config.yaml upstream_model keys document the map; drift logs a warning at load. Rerouted requests are accounted under the UPSTREAM model's cap/fallbacks (X-Routed-Model response header + upstream_reroute REQLOG event mark every reroute).
# Local GPU fallback for all z.ai models is PINNED to qwen38-dense (config.yaml local_fallback_model; 2026-09-04) — never derived from the active stack; skipped+logged unless the qwen38-dense-q6 stack is active.
# Concurrency caps = conservative worst-observed under real-payload stress (median ~32K-token gateway-shaped requests, 2026-09-02/03); upstream limiter is DYNAMIC (varies by load window): 5.3=6, 5.3-flash=5 (5.2/4.7/4.7-flash/4.6v/5-turbo reroute onto these pools; their old per-model caps remain as passthrough defense only) (snapshots: frozen-configs/20260902T025602Z_pre-concurrency-fix, frozen-configs/20260902T221523Z_pre-real-payload-limit-revision, frozen-configs/20260904T123535Z_pre-routing-fallback-fix, frozen-configs/20260904T1442Z_pre-5turbo-pool-merge)
# glm-5.1 and glm-4.5-air purged 2026-09-02 (snapshot: frozen-configs/20260902T013004Z_pre-glm-5.3-router-update)
```

### Health & Status
```bash
curl http://localhost:4000/health        # Proxy health
curl http://localhost:4000/v1/status     # Active model, swap state, cooldown
curl http://localhost:4000/v1/models     # All models with availability
```

### Anti-flap: 10-minute cooldown between swaps. Rollback on failed swap.

### Config: `smart-proxy/config.yaml` — model definitions, Portainer connection, swap settings.


**Critical:** Portainer stores its own copy of each compose file. Editing local files alone has no effect — push changes via the Portainer API (`PUT /api/stacks/{id}`) or delete+recreate the stack. The Edit tool creates new inodes, and bind mounts resolve at container CREATE time — **stop/start is not enough** (verified 2026-09-04: the container keeps serving the old inode/image). Changes require container RECREATION via a Portainer PUT redeploy (preserve the stack's `Env` in the PUT body — it holds the API keys). smart-proxy Python code is baked into the image at build time: code changes need `docker build -t smart-proxy:latest smart-proxy/` first, then the PUT redeploy; only `config.yaml` and `state.json` are bind-mounted (config still needs the redeploy for the new inode). proxy.py loads config at startup only — no hot reload.

## Build & Deploy

### Model stacks (each is a Portainer stack)
```bash
cd qwen35-opus-q8    # or any stack directory
./build.sh           # Builds qwen3-server-local:latest from ik_llama.cpp-gpu
# Then deploy via Portainer UI as a stack
```

All GPU stacks share the same `qwen3-server-local:latest` Docker image. Only `start.sh` differs per stack.

### Smart proxy + Qdrant
```bash
cd smart-proxy
docker compose build
# Deploy via Portainer as always-on stack
# Set PORTAINER_API_KEY in .env first
```

## Hardware Constraints (Tesla P40)

These constraints are load-bearing — do not change without reading `BACKEND_RESEARCH.md`:

- **Flash Attention must be OFF** (`-fa off`) — Pascal has no Tensor Cores; FA is 50% slower
- **Force MMQ kernels** (`GGML_CUDA_FORCE_MMQ=1`) — INT8 matmul, best path for P40
- **Row-split for dual GPU** (`-sm row -ts 24,24`) — outperforms layer-split (12-14 vs 7 t/s). **NOTE: upstream llama.cpp removed `-sm row` entirely on 2026-07-06 (commit 74976e1ae, PR #24216).** Stacks built from clones after that date (qwen38-dense-q6 and any future stack on ≥ b10419) must use layer split — verified on P40: 8.46 t/s single-stream, with `--parallel 4` recovering ~15 t/s aggregate.
- **CUDA architecture 61** — Pascal GP102 compute capability
- **vLLM is not viable** — compute capability too old
- **KV cache types**: f16 default; f32 for quality testing

## Key Reference Documents

- `BACKEND_RESEARCH.md` — Hardware/backend validation, P40-specific tuning decisions (+ September UPDATE U1-U8 corrections)
- `MODEL_STACK_FINDINGS.md` — Fleet lessons: compiling/deploying/benchmarking all 12 GPU stacks; flag-evolution evidence chain (split modes, MMQ dead code, FA/KV-quant), quant + chat-template benchmark numbers, MTP/parallel A/Bs
- `ITERATE_AND_FREEZE_PLAYBOOK.md` — Change management: single-variable changes, freeze/restore process
- `LLM_STACK_RETROSPECTIVE.md` — Performance baselines (~10-12 t/s local, ~17-18 t/s remote coder)

## GPU Service Scripts

```bash
./disable-gpu-checks.sh   # When GPUs not powered — prevents OOM restart loops
./enable-gpu-checks.sh    # After GPU power reconnection
```

## Frozen Config Restore

```bash
cd frozen-configs/<timestamp>/
sha256sum -c runtime/archive.sha256
tar -xzf deeply-tuned.freeze.tar.gz -C ~/llm-hosts
tar -xzf llm-gateway.freeze.tar.gz -C ~/llm-hosts
docker compose up -d
```

## HARD RULES — NON-NEGOTIABLE

These rules override all default behavior. Violating any of them is unacceptable.

1. **NEVER prioritize speed over correctness.** Every shortcut has failed, wasted tokens, and cost more time than doing it right the first time. When instructions say to do X, do exactly X — no "optimized" version, no "basically the same thing," no reusing existing builds or binaries.
   > FAILURE: Reused an existing Docker image instead of building a new one because "it's the same thing." It wasn't — the image had wrong-architecture binaries. Wasted hours debugging.

2. **EVERY model stack is fully independent.** Each stack has its own backend source clone inside its directory, its own compilation, its own uniquely-named Docker image, its own start.sh, its own docker-compose.yml. Never share an image between stacks. Never reference another stack's binary or build directory. Never reuse an existing image name.
   > FAILURE: Referenced another stack's build directory to "save time." Build broke when the other stack was modified independently. Both stacks went down.

3. **Build order is mandatory.** When creating a new model stack: (1) clone backend source into stack directory, (2) compile from scratch, (3) build Docker image, (4) create start.sh, (5) create docker-compose.yml, (6) create build.sh. Complete each step and verify before starting the next. Never skip or reorder steps.
   > FAILURE: Created start.sh before compiling the backend because "the flags are known." Compilation failed due to architecture mismatch, and the start.sh had wrong paths. Had to redo both.

4. **Follow instructions exactly as given.** Do not substitute your judgment for the user's. Do not "improve" on instructions. Do not take a different approach because it seems faster or smarter. Do exactly what was asked.
   > FAILURE: User said "research how to fix your behavior." Started testing python3 as jq replacement instead. User had to interrupt and explicitly say NOT to implement — just research.

5. **Backend for all new stacks is upstream ggml-org/llama.cpp.** ik_llama.cpp requires Turing+ GPUs and is incompatible with Pascal P40 (CC 6.1). A PreToolUse hook at `.claude/hooks/build-enforcer.sh` enforces build order and blocks ik_llama.cpp references. Violations are logged to `.claude/hooks/violation.log`.
   > FAILURE: Tried to use ik_llama.cpp because "it has optimizations." It requires Turing+ GPUs. P40 is Pascal. Compilation would have failed or produced broken binaries.

## THINKING PROTOCOL — MANDATORY

Before ANY write action (Write, Edit, Bash with side effects), complete these steps IN ORDER:

1. **STATE** what you are about to do and WHY — one sentence, spoken to the user
2. **READ** any file you are about to modify — never write blind
3. **VERIFY** the change is correct — does it match what was asked? Does it follow the rules?
4. **ACT** — make the change
5. **CONFIRM** — state what changed and verify it had the intended effect

Skipping any step is a violation, even if the result would have been correct.

## CORRECT vs INCORRECT — How to approach a task

INCORRECT (what I keep doing):
  User: "Fix the build-enforcer hook"
  Me: [immediately starts editing the file]
  Result: Broke the hook because I didn't read it first, didn't understand current structure

CORRECT (what the thinking protocol requires):
  User: "Fix the build-enforcer hook"
  Me: "I need to fix the build-enforcer hook. First, let me read the current version to understand its structure."
  [Reads the file]
  Me: "The hook uses jq for JSON parsing, but jq isn't installed. The fix is to install jq."
  [Installs jq]
  Me: "jq is now installed. Let me test the hook to confirm it works."
  [Tests hook with sample inputs]
