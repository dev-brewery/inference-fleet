# Stack Status: The Machine is Running

Date: 2026-03-31
Scope: State of the stack after three weeks of iterative development, from bare metal to a production agent ecosystem.

## Where We Started

Three weeks ago this was a server with two secondhand Tesla P40s and an idea. No routing, no orchestration, no monitoring. Just a llama.cpp binary, a model file, and `curl`. Every model change meant SSH, docker compose down, edit, docker compose up, pray.

## Where We Are Now

The stack is alive and it's working. Not in the "it compiled" sense — in the "it's been handling hundreds of requests an hour for days without intervention" sense.

### The Numbers (40-hour window ending tonight)

- **8,129 requests** through the quality gate
- **328 evaluated by the judge**, 314 passed first attempt (95.7% first-attempt pass rate)
- **196 tool nudges** fired — Qwen correctly pre-classified which tool GLM needed
- **348 tool_use completions** vs 61 end_turn — GLM is executing tools, not narrating about them
- **14 total exhausted failures** across 8,129 requests — 0.17% failure rate
- **Zero human interventions** required

The Z.AI 500 errors (19 of them) are theirs, not ours. The system handled them gracefully — retried, fell back, kept moving.

### What's Actually Running

```
Port 4000   Smart Proxy          — routing, auto-swap, anti-flap, queue management
Port 8080   Qwen3-Next-80B       — 98k context, MoE workhorse on dual P40
Port 8090   Nomic Embed v1.5     — CPU embeddings, always on
Port 8091   Qwen3-4B Classifier  — request triage in <600ms
Port 8092   Qwen3-4B Helper      — tool matching, summarization, RAG (now --parallel 2)
Port 6333   Qdrant               — vector DB for RAG
Port 8093   Qdrant MCP           — vector search tool server
Port 8095   System MCP           — GPU/container/disk status tool server
Port 3000   Grafana              — dashboards + email alerts (newly configured)
Port 9090   Prometheus           — metrics collection
Port 8081   cAdvisor             — container metrics
Port 9100   Node Exporter        — host metrics
```

Four GPU model stacks ready to swap in via Portainer API. One active at a time, 10-minute anti-flap cooldown, automatic rollback on failed swaps.

### The Quality Gate Pipeline

This is the thing I'm most proud of. The problem seemed intractable at first: GLM would receive a request with 27 tool definitions and respond with "Sure, I'll look that up for you!" instead of actually calling the tool. The retry loop would burn three 12-second Z.AI round trips and still return narration.

The fix was elegant once we found it: a 4-billion parameter model running on 4 CPU cores, spending 40 tokens and 2 seconds to pre-classify which tool the request needs. That classification gets injected as a structured nudge into the Z.AI payload. GLM sees "Use the web_search tool" right before the user's message, and suddenly it produces tool_use blocks on the first attempt.

Less is more turned out to be the critical insight. When the tool matcher tried to send tool descriptions (200+ tokens), it timed out half the time. When we stripped it down to just a comma-separated list of names (40 tokens), it got fast enough to fit in the latency budget. A small model making a classification decision doesn't need to understand the tools — it just needs to pattern-match the request to a name.

### The Monitoring Story

For three weeks we flew by `docker logs` and `curl /health`. Tonight we wired up Grafana to email alerts via InMotion's SMTP relay. There's a standing alert on helper queue pressure that will fire if `--parallel 2` isn't enough. There's a one-shot cron job on April 2nd that will email a before/after comparison of timeout rates.

It feels like the difference between a prototype and infrastructure.

### Hardware Utilization

The EPYC 7302 is barely working. Load average sits at 0.04-0.17 with the full stack running. The GPU model claims 32 threads but only bursts during prompt eval. The two CPU agents (classifier + helper) are capped at 4 cores each. 109 GB of RAM available. We could run three more helpers before anything gets tight.

The P40s are the constraint and always will be. No Tensor Cores, no Flash Attention, compute capability 6.1 in a world that's moved to 9.0. But with the right kernels (GGML_CUDA_FORCE_MMQ), the right split strategy (row-split across both cards), and the right model choices (MoE architectures that only activate 3B of 80B parameters per token), they deliver 10-14 tok/s. That's not fast. But it's fast enough for an agent that's making tool calls and processing results, not writing novels.

### What We Learned

**Single-variable changes work.** The iterate-and-freeze playbook saved us multiple times. When something broke, we knew exactly which change caused it because we only ever changed one thing. When we needed to roll back, the frozen configs were right there with checksums.

**Small models are better classifiers than big models.** A 4B model with a 40-token prompt makes faster, more reliable classification decisions than a frontier model with a detailed rubric. The small model doesn't overthink. It sees "search the web for" and outputs "web_search" in under a second.

**The proxy should be dumb.** Pure pass-through routing with no token inspection, no payload modification (except the quality gate path), no clever middleware. Smart enough to route, dumb enough to be reliable. Every time we considered adding intelligence to the proxy itself, the simpler answer was to put it in a sidecar agent.

**Budget hardware has a longer tail than people think.** These P40s are from 2016. The EPYC 7302 is a $150 server pull. Total hardware cost is less than two months of frontier API usage. And it runs 24/7, no rate limits, no credit exhaustion, no vendor rug-pulls.

### What's Next

The `--parallel 2` change on the helper is tonight's experiment. If it drops the 44% timeout rate meaningfully, we'll know the bottleneck was request queuing, not raw inference speed. If it doesn't, we'll try `--parallel 3` or bump the timeout budget.

The context-overflow failover plan is designed and shelved. If truncation comes back, we have a complete implementation plan for auto-rerouting oversized requests to Z.AI cloud models, including the format conversion layer. But it hasn't been a problem since we added stop_reason logging, so it stays on the shelf.

The stack is stable. The monitoring is real. The alerts will tell us when something needs attention.

Three weeks from bare metal to here. Not bad for a couple of decade-old GPUs and a server that cost less than a nice dinner.
