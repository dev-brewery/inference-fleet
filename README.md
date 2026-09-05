# inference-fleet

The complete operational record of a self-hosted LLM inference server: twelve GPU model stacks compiled from source, benchmarked, and served behind a routing proxy on a ~$2,000 machine with dual 2016-era Tesla P40s.

Companion repo to [smart-proxy](../smart-proxy) (the routing/reliability layer) and the blog series at [michaelbrewer.me](https://michaelbrewer.me) (the stories and reversals).

## Hardware

AMD EPYC 7302 (16c/32t), 128 GB DDR4-2666 ECC, 2x NVIDIA Tesla P40 (24 GB, compute capability 6.1: no Tensor Cores, no vLLM, no shortcuts). Measured results anyway: 41 tok/s on a 26B MoE, 13-17 tok/s on a 27B dense with 262k context, 8,129 requests over one 40-hour window at 0.17% failure.

## Layout

- **docs/**: the findings record. Start with `MODEL_STACK_FINDINGS.md` (its §0 catalogs every claim that got overturned in six months, with the evidence class that overturned it). `BACKEND_RESEARCH.md` is the March baseline with dated September corrections U1-U8. `ITERATE_AND_FREEZE_PLAYBOOK.md` is the change-management discipline. `CLAUDE.md` is the operating manual the on-box agent works under, hard rules included.
- **stacks/**: eleven GPU model stacks (Qwen 3.5/3.6/3.8, Gemma 4, 80B MoEs). Each is independent: its own build.sh, start.sh with dated A/B evidence in the header comments, and compose file. The flag matrices differ per model family for measured reasons, not vibes.
- **benchmarks/**: the deeply-tuned harness. MCQ suite at fixed seed, template comparison matrix, Q6/Q8 comparisons, stream-stability monitoring, and the versioning/ gate: candidates are promoted by ledger rules that once invalidated their own author's promotion for a missing test report.
- **loadtest/**: concurrency test drivers, including the real-payload stress harness that exposed dynamic vendor rate limits.
- **monitoring/**: Prometheus/Grafana/cAdvisor stack, deliberately independent of GPU swaps so the metrics survive what they measure.
- **mcp-servers/**: two MCP servers exposing vector search (Qdrant) and system state (GPU, containers, disk) so agents can self-diagnose.
- **experiments/**: the vLLM-on-Pascal attempt, kept because a ruled-out experiment is evidence, not failure.

## Provenance

Everything here ran (or runs) in production on the box described above. Secrets, keys, and internal addresses are scrubbed; `.env.example` files mark what you'd fill in. Model weights are obviously not included. Dated measurements reference the files they were recorded in; where something was never tested, the docs say so.
