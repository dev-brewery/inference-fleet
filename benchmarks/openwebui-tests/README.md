# OpenWebUI Reliability Tests

Run these tests **through OpenWebUI**, not directly against llama.

## Requirements

- Python 3.10+
- OpenWebUI base URL (example: `http://openwebui-host.lan:3003`)
- OpenWebUI API key / bearer token
- A model id visible to OpenWebUI

## Quick Start

```bash
cd ~/llm-hosts/deeply-tuned/openwebui-tests
cp .owui.env.example .owui.env
# edit .owui.env with your real token/model
./run_openwebui_tests.sh
```

`run_openwebui_tests.sh` auto-loads `./.owui.env` if present, so it does not rely on parent-shell exports.

## Optional Env Vars

- `OWUI_STREAM_RUNS` (default `20`): number of stream stability runs
- `OWUI_TIMEOUT_S` (default `180`): timeout per request
- `OWUI_OUT_DIR` (default `./results`)
- `OWUI_ENDPOINT_MODE` (default `auto`): one of `auto`, `api`, `openai`

## What It Tests

1. Authenticated health/version reachability.
2. Model listing endpoint.
3. Non-stream chat completion.
4. Stream completion continuity + `[DONE]` sentinel.
5. Repeated stream stability (N runs).
6. Tool-call payload roundtrip (`tools` + `tool_choice`).
7. Tool-result follow-up turn.

## Output

- Console summary with pass/fail per test.
- JSON report in `results/openwebui_test_report_<timestamp>.json`.
