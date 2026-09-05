# Versioning and Release Control

This folder provides strict candidate versioning for `deeply-tuned` so changes are:

- Captured immutably
- Evaluated against objective gates
- Promoted only when passing
- Rejected with evidence when failing

## Workflow

1. Create candidate snapshot.
2. Attach test metrics JSON.
3. Evaluate against gates.
4. Promote only if pass.

## Commands

From `~/llm-hosts/deeply-tuned`:

```bash
# 1) snapshot current state
./versioning/new_candidate.sh "short-label" "optional notes"

# 2) evaluate with metrics file
./versioning/evaluate_candidate.sh <candidate_id> /abs/path/metrics.json

# 3) promote if PASS
./versioning/promote_candidate.sh <candidate_id>
```

## Required Metrics JSON

Evaluation expects metrics in this shape:

```json
{
  "openwebui_report_path": "/abs/path/openwebui_test_report_YYYYMMDDTHHMMSSZ.json",
  "openwebui_tests_passed": true,
  "stream_success_rate": 99.5,
  "real_requests_pass_at_2": 83.3,
  "gen_tps": 10.2
}
```

Hard requirement:

- `openwebui_report_path` must exist and its summary must show `passed == total`.
- Evaluation fails if report evidence is missing or inconsistent.

## Gate File

Gate thresholds are in `versioning/gates.json`.

## Artifacts

- Candidate snapshots: `versioning/candidates/<candidate_id>/`
- Immutable release records: `versioning/releases/<candidate_id>/`
- Decision log: `versioning/ledger.jsonl`
- Active release pointer: `versioning/current_release.json`
