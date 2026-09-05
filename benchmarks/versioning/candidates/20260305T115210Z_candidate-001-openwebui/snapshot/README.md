# Deeply Tuned (Daily Driver)

This stack is a clean `llama.cpp`-based inference engine tuned for:

- AMD EPYC 7302
- 2x Tesla P40 (24 GB + 24 GB)
- Dense models fully loaded in GPU VRAM
- 32k context target

## Why this engine

For pure-VRAM dense models, mainline `llama.cpp` is the baseline backend to beat.
This folder intentionally ignores MoE/DeepSeek hybrid tuning and focuses on stable dense throughput.

## Recommended model ladder (Qwen3-32B GGUF)

Source: `unsloth/Qwen3-32B-GGUF` on Hugging Face.

- `Qwen3-32B-Q6_K.gguf` (~29.0 GB): default daily-driver candidate for 32k with headroom.
- `Qwen3-32B-Q8_0.gguf` (~39.5 GB): stretch candidate, may be too tight at 32k depending on KV/cache overhead.

## Quick start

1. Copy env file:

```bash
cp .env.example .env
```

2. Build image:

```bash
./build.sh
```

3. Start server:

```bash
docker compose up -d
```

4. Watch GPUs:

```bash
watch -n 1 'nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv,noheader'
```

5. Run sanity benchmark:

```bash
./benchmark.sh
```

## Optional challenger profile (Qwen3.5-35B-A3B)

This folder includes a second env preset for A/B testing:

- baseline: `.env` (Qwen3-32B-Q6_K)
- challenger: `.env.qwen35-a3b`

Switch to challenger profile:

```bash
cp .env.qwen35-a3b .env
./build.sh
docker compose up -d
./benchmark.sh
```

Switch back to baseline profile:

```bash
cp .env.example .env
docker compose up -d
./benchmark.sh
```

## Tuning intent

Defaults are tuned for Pascal:

- `GGML_CUDA_FORCE_MMQ=1`
- `-sm row -ts 24,24` (dense multi-GPU path)
- `--flash-attn off` (safe baseline on Pascal)
- `-ngl 999` (full offload attempt)

If you want the absolute largest model/quant at 32k, test one variable at a time:

1. quant (`Q6_K` -> `Q8_0`)
2. context (32768 fixed)
3. batch/ubatch
4. cache types

## Structured reliability mode

Flag tuning has reached diminishing returns. This folder now includes a structured control plane:

- Frozen runtime profile: `profiles/production.env`
- Profile switcher: `./use_profile.sh production`
- Structured router: `router/router.py`

### Apply production baseline

```bash
./use_profile.sh production
docker compose up -d
```

Endpoint behavior:

- Public endpoint remains unchanged at `:8080`.
- Router gateway handles incoming `/v1/chat/completions` on `:8080`.
- `llama-server` runs behind gateway on internal `127.0.0.1:8081`.
- During restart, `/health` may become available before model warmup completes; wait for container health to turn healthy.

Gateway knobs (in `.env`):

- `ROUTER_GATEWAY_MODE=on`
- `BACKEND_PORT=8081`
- `GATEWAY_MAX_RETRIES=2`
- `GATEWAY_FAIL_ON_VERIFY=off` (recommended for daily-driver fail-open behavior)

### Run router (example request)

```bash
./router/run_router.sh
```

Run with strict verifier gate (non-zero exit on failed checks):

```bash
./router/run_router.sh ./router/examples/incident_request.json --fail-on-verify
```

### Router request contract

Router requests are JSON objects with required fields:

- `goal` (string)
- `constraints` (list of strings)
- `output_format` (string)
- `acceptance_checks` (list of strings)

Optional:

- `task_type`: `auto|math_logic|code|ops|planning|writing`
- `context` (list of strings)
- `metadata` (object)

Schema reference: `router/request_schema.json`

Verifier behavior:

- Default: runs acceptance + route-specific checks and returns a verification report.
- `--fail-on-verify`: fail closed for automation pipelines.
- `--no-verify`: bypass gates (debug only).
- `--max-retries N`: run targeted repair passes when verification fails.

Phase-5/6 controls now active:

- Repair loop: verifier failures trigger corrected retries with concrete failure reasons.
- Tool-assisted checks:
  - `math_logic`: deterministic formula checks for common patterns (divisibility count, clock angle, two-worker rate).
  - `code`: Python syntax parse when code is present.

## Versioning and Promotion Control

Use strict candidate versioning to keep what works and reject what fails.

Commands:

```bash
cd ~/llm-hosts/deeply-tuned
./versioning/new_candidate.sh "label" "notes"
./versioning/evaluate_candidate.sh <candidate_id> /abs/path/metrics.json
./versioning/promote_candidate.sh <candidate_id>
```

See:

- `versioning/README.md`
- `versioning/gates.json`
- `versioning/metrics.example.json`
