# Iterate + Freeze Playbook

Purpose: define a strict, repeatable process to improve a working LLM stack without destabilizing production.

## 1) Golden Rules

1. Never change multiple variables at once.
2. Every candidate must be testable by script, not judgment.
3. Promotion requires passing gates on the real client path (OpenWebUI/API path), not only local backend tests.
4. Freeze immediately after a known-good promotion.
5. New experiments must run in separate folders/ports from active production.

## 2) Folder Strategy

- Keep each implementation lane isolated:
  - `deeply-tuned/` for local dense daily-driver path
  - `llm-gateway/` for routing/policy
  - separate folder for DeepSeek or large-model experiments

No cross-lane edits until a candidate passes and is promoted.

## 3) Iteration Lifecycle

### Step A: Baseline Capture

Before any change:
- record current config
- confirm health endpoints
- run a short regression benchmark

Minimum checks:
- model list succeeds
- one non-stream request succeeds
- one stream request succeeds
- tool-call path succeeds (if used)

### Step B: Single Change Candidate

Create a candidate with one explicit change only:
- one flag tweak
- one prompt policy tweak
- one routing rule tweak

Document:
- hypothesis
- expected impact
- rollback command

### Step C: Gate Evaluation

A candidate passes only if all required gates pass:
- reliability gates (no hangs/timeouts in test suite)
- quality gates (task-pass threshold)
- throughput floor (tok/s floor)
- OpenWebUI-path validation (not backend-only)
- deploy-verification gate (added 2026-09: the change is observable in the running container — `docker exec` grep or feature-observable behavior — not just an API 200 from the deploy step)

If any gate fails: reject candidate and log why.

### Step D: Promote

When candidate passes:
- mark as promoted
- update current release pointer
- stop further changes until freeze is done

### Step E: Freeze

Create timestamped freeze snapshot:
- config file copies
- compressed archives
- runtime metadata (`docker ps`, `nvidia-smi`)
- checksums
- restore instructions

Reference:
- current freeze lives in `frozen-configs/LATEST`

## 4) Required Artifacts Per Candidate

1. Candidate metadata (what changed, why).
2. Metrics JSON (throughput/reliability/quality).
3. OpenWebUI test report path.
4. Pass/fail decision log.
5. Rollback command.

No artifacts, no promotion.

## 5) Promotion Criteria Template

Use explicit thresholds (adjust per project):
- `openwebui_tests_passed == true`
- `stream_success_rate >= 99%`
- `real_requests_pass_at_2 >= target`
- `gen_tps >= target_floor`

Targets must be decided before running the candidate.

## 6) Change Control in Live Sessions

1. Start each session by reading:
   - this playbook
   - current freeze manifest
   - current release pointer
2. Confirm which lane is active.
3. Refuse ad-hoc architecture churn in production lane.
4. If session is interrupted mid-change, re-verify live config before continuing.

## 7) Freeze Procedure (Canonical)

1. Pick UTC timestamp ID.
2. Copy active configs for each lane.
3. Archive each lane (`tar.gz`).
4. Save runtime metadata.
5. Compute SHA256 checksums.
6. Write `FREEZE_MANIFEST.md`.
7. Update `frozen-configs/LATEST` symlink.

## 8) Rollback Procedure (Canonical)

1. Stop affected stack(s).
2. Restore from freeze archives.
3. **Recreate containers — not just restart** (corrected 2026-09: bind mounts and image layers resolve at container CREATE time; stop/start re-attaches the old inode and old image and silently serves pre-rollback code — verified in production). For Portainer stacks this means a `PUT /api/stacks/{id}` redeploy, **preserving the stack's `Env`** — it holds the API keys. Never print the PUT response body; it echoes key values back.
4. Run smoke checks.
5. Re-run gate subset to confirm parity.
6. Verify the rollback is live *inside the container* (`docker exec` grep, or observe the old behavior). A 200 from Portainer means "accepted," not "serving."

## 9) Anti-Patterns to Avoid

1. “Quick fixes” without measurable gates.
2. Changing auth/routing/perf flags simultaneously.
3. Validating only with direct curl when production path is OpenWebUI.
4. Keeping experimental and production configs in the same runtime.
5. Treating a Portainer 200 — or a container restart — as deployment verification (added 2026-09; stop/start served stale code in production until someone grepped the container).

## 10) Session Handoff Requirements

Every session handoff must include:
- current lane
- current promoted candidate
- known blockers
- exact next command set

This prevents context loss and repeated churn across sessions.
