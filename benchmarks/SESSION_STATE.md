# Session State Handoff

Last updated: 2026-03-05 UTC

## Primary Objective

Deliver a reliable daily-driver local inference workflow with strict, evidence-based promotion gates.

## Ground Rules Agreed

1. No unstable transport wrapper behavior in user path.
2. Keep what works, reject what fails, with auditable evidence.
3. Candidate promotion must require real OpenWebUI test proof.

## Current Runtime State

- Direct `llama-server` is restored on public `:8080`.
- Wrapper mode is disabled in active profile.
- Container state confirmed healthy during last checks.

## Candidate/Versioning Status

### Versioning system implemented

- `versioning/new_candidate.sh`
- `versioning/evaluate_candidate.sh`
- `versioning/promote_candidate.sh`
- Ledger: `versioning/ledger.jsonl`
- Current pointer: `versioning/current_release.json`
- Gates: `versioning/gates.json`

### Hard evidence enforcement implemented

`evaluate_candidate.py` now requires:

1. `openwebui_report_path` in metrics JSON
2. Report file exists and parses
3. Report summary has `passed == total`
4. `openwebui_tests_passed` matches report summary

If not, evaluation fails.

### Current release pointer

- Intentionally unset (`current_release.json`) until real OpenWebUI-evidenced candidate passes.

### First real candidate

- `20260305T115210Z_candidate-001-openwebui`
- Snapshot created
- Not yet evaluated with real OpenWebUI report

## OpenWebUI Test Harness Status

Harness path:

- `openwebui-tests/test_openwebui.py`
- `openwebui-tests/run_openwebui_tests.sh`
- `openwebui-tests/README.md`

It tests:

1. version endpoint
2. models endpoint
3. non-stream chat
4. stream once (`[DONE]`)
5. stream stability loop
6. tool-call roundtrip
7. tool follow-up turn

## Blocking Issue at End of Session

The current shell/session does not have these env vars set:

- `OWUI_BASE_URL`
- `OWUI_API_KEY`
- `OWUI_MODEL`

The user had them in another terminal, but env does not carry across this session.

## Exact Next Steps (Resume Checklist)

1. Set env vars in active session:

```bash
export OWUI_BASE_URL="http://openwebui-host.lan:3003"
export OWUI_API_KEY="..."
export OWUI_MODEL="..."
```

2. Run harness:

```bash
cd ~/llm-hosts/deeply-tuned/openwebui-tests
./run_openwebui_tests.sh
```

3. Capture generated report path, create metrics JSON for candidate (include `openwebui_report_path`):

```json
{
  "openwebui_report_path": "/abs/path/openwebui_test_report_YYYYMMDDTHHMMSSZ.json",
  "openwebui_tests_passed": true,
  "stream_success_rate": 99.0,
  "real_requests_pass_at_2": 80.0,
  "gen_tps": 9.0
}
```

4. Evaluate candidate:

```bash
cd ~/llm-hosts/deeply-tuned
./versioning/evaluate_candidate.sh 20260305T115210Z_candidate-001-openwebui /abs/path/metrics.json
```

5. Promote only if evaluation returns `pass`:

```bash
./versioning/promote_candidate.sh 20260305T115210Z_candidate-001-openwebui
```

## Key Files to Read First in New Session

- `~/llm-hosts/deeply-tuned/SESSION_STATE.md`
- `~/llm-hosts/deeply-tuned/versioning/README.md`
- `~/llm-hosts/deeply-tuned/versioning/gates.json`
- `~/llm-hosts/deeply-tuned/versioning/evaluate_candidate.py`
- `~/llm-hosts/deeply-tuned/openwebui-tests/test_openwebui.py`

