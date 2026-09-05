# Execution Checklist: Reliable Daily Driver

Use this as the operational runbook for implementing and validating reliability.

Status legend:

- `[ ]` not started
- `[-]` in progress
- `[x]` complete

## A) Baseline Lock

- [x] Keep direct `llama-server` on `:8080` (no transport wrapper in path).
- [x] Freeze production profile in `profiles/production.env`.
- [ ] Record baseline perf snapshot:
  - Command: `./benchmark.sh`
  - Capture: prompt t/s, generation t/s, GPU util.

Acceptance:

- `docker logs` shows direct `llama-server` on `0.0.0.0:8080`.
- Baseline benchmark report stored in `bench-results/`.

## B) OpenWebUI Prompt/Policy Pack

- [ ] Create class templates in OpenWebUI for:
  - `math_logic`
  - `code`
  - `ops_security`
  - `planning`
  - `general`
- [ ] Define output contracts per class.
- [ ] Configure class routing instructions in OpenWebUI.

Acceptance:

- Manual sample for each class returns expected structure.
- Templates versioned/exported (screenshot or JSON export saved).

## C) OpenWebUI Tool Checks

- [ ] Add math verification tool.
- [ ] Add code syntax/command verification tool.
- [ ] Add ops/planning coverage checker tool.
- [ ] Validate tool schemas and error handling.

Acceptance:

- Each tool callable from OpenWebUI chat.
- Tool output is machine-checkable and deterministic.

## D) Retry/Correction Policy

- [ ] Configure one correction retry for failed checks (`pass@2` path).
- [ ] Ensure retry prompt includes explicit failure reasons only.
- [ ] Ensure final unresolved failures return uncertainty, not fabricated confidence.

Acceptance:

- Failure case demonstrates:
  - attempt 1 fail
  - attempt 2 corrected or explicit uncertain response.

## E) OpenWebUI API Test Harness

- [x] Test harness created:
  - `openwebui-tests/test_openwebui.py`
  - `openwebui-tests/run_openwebui_tests.sh`
- [ ] Run authenticated test suite against OpenWebUI.

Command:

```bash
cd ~/llm-hosts/deeply-tuned/openwebui-tests
export OWUI_BASE_URL="http://openwebui-host.lan:3003"
export OWUI_API_KEY="..."
export OWUI_MODEL="local"
./run_openwebui_tests.sh
```

Acceptance:

- All core tests pass:
  - version
  - models
  - non-stream chat
  - stream once + `[DONE]`
  - tool call roundtrip
  - tool follow-up

## F) Stream Stability Soak

- [ ] Run stream soak through OpenWebUI with `OWUI_STREAM_RUNS=50`.
- [ ] Run mixed workload soak (stream + non-stream interleaving).
- [ ] Capture incomplete stream count and timeout count.

Acceptance:

- Stream completion rate `>=99%`.
- No silent half-stream failures.

## G) Quality Gate (Real Requests)

- [ ] Run real-request benchmark workflow with OpenWebUI policy/tool stack enabled.
- [ ] Record:
  - `pass@1`
  - `pass@2`
  - failure taxonomy by class
- [ ] Tune top 3 failure categories and rerun.

Acceptance:

- `pass@2 >= 80%` on real-request suite.

## H) Speed Gate

- [ ] Compare post-policy latency vs baseline.
- [ ] Measure median and P95 completion latency by class.
- [ ] Verify generation throughput remains within acceptable degradation.

Acceptance:

- Median speed degradation within agreed budget (default max 20%).

## I) Production Rollout

- [ ] Stage enablement by class:
  - `math_logic` -> `code` -> `ops_security` -> `planning` -> `general`
- [ ] 24-48 hour observation window per stage.
- [ ] Rollback criteria documented and tested.

Acceptance:

- No stage rollback required for two consecutive stages.

## J) Weekly Regression Operations

- [ ] Schedule weekly run of:
  - OpenWebUI harness
  - real-request quality suite
  - stream soak
- [ ] Save reports in dated folder.
- [ ] Track trendline for pass rate, stream stability, and latency.

Acceptance:

- Regression trend is stable or improving week over week.

## Report Template (Per Run)

- Date/time:
- Profile hash / env:
- Model:
- pass@1:
- pass@2:
- stream completion rate:
- median latency:
- P95 latency:
- top 3 failures:
- remediation actions:

