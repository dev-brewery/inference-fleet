# Implementation Plan: Reliable Daily-Driver Inference on EPYC + 2x P40

## 1) Purpose

Define a production-ready approach to use the current local model stack with high confidence in:

- Accuracy for real tasks
- Stable response behavior in OpenWebUI
- Predictable speed and latency

This plan explicitly avoids inserting a network wrapper between OpenWebUI and `llama-server` due to observed streaming/UX regressions.

## 2) Current Baseline (Locked)

### Runtime

- Backend: `llama.cpp` server directly on `:8080`
- Model: `Qwen3-32B-Q6_K.gguf`
- Context: `16k`
- GPUs: both P40s fully offloaded
- Determinism settings: fixed seed, no-think server mode, prompt cache off

### Why this baseline

- Good speed for this hardware (`~10 tok/s` generation class)
- Stable deployment behavior
- No proxy-induced stream issues

## 3) Goals and Non-Goals

### Goals

1. Achieve `>=80%` pass on real-request benchmark suite.
2. Maintain stream reliability in OpenWebUI (`[DONE]` completion semantics, no mid-response stalls).
3. Keep user-visible speed acceptable for daily driver workloads.

### Non-goals

1. Perfect correctness on all request types.
2. Single-pass reliability for all edge cases.
3. Reintroducing HTTP middleware in the inference path.

## 4) Reliability Strategy (No HTTP Wrapper)

Reliability will be implemented at the **workflow/prompt/tooling layer**, not transport layer.

### Core approach

1. Keep direct model endpoint unchanged.
2. Add structured request policy in OpenWebUI:
- classify request type
- apply route-specific prompt template
- require answer contract
3. Add verifier tools in OpenWebUI workflows:
- numeric checks
- syntax/lint checks
- policy/coverage checks
4. Add bounded correction loop:
- attempt 1: normal response
- attempt 2: targeted correction with explicit failures
- fail closed with uncertainty if still invalid

## 5) Request Classes and Policies

Define 5 classes:

1. `math_logic`
2. `code`
3. `ops_security`
4. `planning`
5. `general`

Each class gets:

- Prompt template
- Output format contract
- Verification checklist
- Max retry count

### Example class policies

#### `math_logic`

- Output must include final numeric answer.
- Verify with deterministic calculator/tool expression.
- Retry if mismatch.

#### `code`

- Output code block or command only when requested.
- Run syntax check (`python -m py_compile` or shell lint where applicable).
- Retry if parse/lint fails.

#### `ops_security`

- Require containment + rollback/mitigation + owner + verification criteria.
- Retry if any section missing.

#### `planning`

- Require ordered steps, risks, dependencies, rollback path.
- Retry if structure missing.

## 6) OpenWebUI Implementation Work

### Phase A: Prompt/Policy Pack

1. Create system prompt templates per class.
2. Create output contracts per class.
3. Configure model presets in OpenWebUI for each class.

Deliverable:

- Importable prompt set + mapping doc.

### Phase B: Tool Check Functions

1. Add calculator/check tool for numeric validation.
2. Add code syntax checker tool.
3. Add structure/policy checker tool (keyword/section checks).

Deliverable:

- Tool definitions and expected I/O schemas.

### Phase C: Retry Logic

1. Build retry instruction template:
- include exact failures
- require corrected answer only
2. Limit retries to 1 or 2 based on class.

Deliverable:

- Retry policy matrix by class.

## 7) Benchmarking and Gates

Use the existing real-request suite as the quality gate.

### Metrics

1. `pass@1`
2. `pass@2` (after correction)
3. Stream completion success rate
4. Median and P95 response time
5. Tokens/sec (prompt and generation)

### Release gates

1. `pass@2 >= 80%` on real-request suite
2. Stream stability: `>= 99%` completed streams in soak run
3. No regression in median speed beyond agreed threshold (e.g., max 20% slower)

If any gate fails:

- no promotion
- collect failure taxonomy
- patch policy/tool checks

## 8) Stream Reliability Validation

Run repeat stream tests through OpenWebUI API:

1. Single stream sanity with `[DONE]`.
2. N-run stream soak (e.g., 50 runs).
3. Mixed load (stream + non-stream interleaving).

Record:

- completed vs incomplete streams
- timeout count
- partial output count

## 9) Operational Observability

Track and retain:

1. Request class
2. attempt count
3. verifier failures by type
4. correction success rate
5. stream completion outcomes

Store in JSON reports per run for weekly review.

## 10) Rollout Plan

### Stage 0: Baseline Freeze

- Lock current direct endpoint + model settings.
- No transport changes.

### Stage 1: Shadow Validation

- Run new policy+tools on benchmark traffic only.
- Compare baseline vs policy results.

### Stage 2: Controlled Enablement

- Enable for one class (`math_logic`) first.
- Measure for 48 hours.

### Stage 3: Full Class Coverage

- Enable `code`, `ops_security`, `planning`, then `general`.

### Stage 4: Production Gate

- Require all release gates before declaring stable daily driver.

## 11) Risk Register and Mitigations

1. **Over-constraining prompts reduces response quality**
- Mitigation: class-specific templates, minimal constraints.

2. **Verifier false positives**
- Mitigation: tune checks per class; separate hard vs soft checks.

3. **Retry loops increase latency**
- Mitigation: only retry on high-risk classes or explicit failures.

4. **Tool failures produce false negatives**
- Mitigation: fallback path and explicit tool-error handling.

## 12) Definition of Done

System is accepted when:

1. OpenWebUI traffic uses direct `:8080` without stream break regressions.
2. Real-request benchmark reaches `>=80%` on `pass@2`.
3. Stream soak test passes `>=99%` completion.
4. Weekly regression report is repeatable and stable.

## 13) Immediate Next Actions (Execution Order)

1. Finalize class templates and output contracts.
2. Implement OpenWebUI tool checks for math/code/ops.
3. Wire one-retry correction for failed checks.
4. Run full benchmark + stream soak and publish report.
5. Tune failures by category until gates are met.
