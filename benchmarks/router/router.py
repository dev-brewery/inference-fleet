#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List

from verifier import verify_response

TASK_TYPES = ["math_logic", "code", "ops", "planning", "writing"]


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_request(data: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    required = ["goal", "constraints", "output_format", "acceptance_checks"]
    for key in required:
        if key not in data:
            errors.append(f"missing required field: {key}")
    if "goal" in data and (not isinstance(data["goal"], str) or len(data["goal"].strip()) < 5):
        errors.append("goal must be a non-empty string (>=5 chars)")
    for list_key in ["constraints", "acceptance_checks", "context"]:
        if list_key in data and not isinstance(data[list_key], list):
            errors.append(f"{list_key} must be a list of strings")
        if list_key in data and isinstance(data[list_key], list):
            bad = [x for x in data[list_key] if not isinstance(x, str)]
            if bad:
                errors.append(f"{list_key} must contain only strings")
    if "acceptance_checks" in data and isinstance(data["acceptance_checks"], list) and len(data["acceptance_checks"]) == 0:
        errors.append("acceptance_checks must contain at least one check")
    if "task_type" in data:
        allowed = {"auto"} | set(TASK_TYPES)
        if data["task_type"] not in allowed:
            errors.append(f"task_type must be one of {sorted(allowed)}")
    return errors


def classify_task(goal: str) -> str:
    text = goal.lower()
    rules = [
        ("code", [r"\bpython\b", r"\bbug\b", r"\bfunction\b", r"\bsql\b", r"\bscript\b", r"\bregex\b", r"\brefactor\b"]),
        ("ops", [r"\bincident\b", r"\boutage\b", r"\bdeploy\b", r"\brollback\b", r"\balert\b", r"\b5xx\b", r"\bsre\b"]),
        ("math_logic", [r"\bcalculate\b", r"\bprobability\b", r"\bprove\b", r"\blogic\b", r"\bangle\b", r"\binteger\b", r"\bdivisible\b"]),
        ("planning", [r"\bplan\b", r"\broadmap\b", r"\bmigration\b", r"\barchitecture\b", r"\bstrategy\b", r"\bphases?\b"]),
    ]
    for task, patterns in rules:
        if any(re.search(p, text) for p in patterns):
            return task
    return "writing"


def load_template(task_type: str, base_dir: Path) -> str:
    template_path = base_dir / "templates" / f"{task_type}.txt"
    if not template_path.exists():
        raise FileNotFoundError(f"missing template: {template_path}")
    return template_path.read_text(encoding="utf-8").strip()


def build_user_prompt(req: Dict[str, Any]) -> str:
    context = req.get("context", [])
    context_block = ""
    if context:
        joined = "\n".join(f"- {c}" for c in context)
        context_block = f"\nContext:\n{joined}\n"
    constraints = "\n".join(f"- {c}" for c in req.get("constraints", []))
    checks = "\n".join(f"- {c}" for c in req.get("acceptance_checks", []))
    return (
        f"Goal:\n{req['goal']}\n\n"
        f"Constraints:\n{constraints}\n\n"
        f"Required output format:\n{req['output_format']}\n\n"
        f"Acceptance checks:\n{checks}\n"
        f"{context_block}"
    )


def _repair_policy(route: str) -> str:
    policies = {
        "code": (
            "Repair policy for code tasks:\n"
            "- Prefer runnable code/command blocks.\n"
            "- Remove explanatory prose unless requested.\n"
            "- If SQL requested, return SQL only.\n"
        ),
        "ops": (
            "Repair policy for ops tasks:\n"
            "- Prioritize containment and rollback first.\n"
            "- Include explicit owner and verification signal.\n"
            "- Keep sequence time-ordered and actionable.\n"
        ),
        "math_logic": (
            "Repair policy for math/logic tasks:\n"
            "- Recompute result carefully.\n"
            "- Include final numeric result explicitly.\n"
            "- Keep explanation to one short sentence unless asked otherwise.\n"
        ),
        "planning": (
            "Repair policy for planning tasks:\n"
            "- Provide ordered steps.\n"
            "- Include risks/dependencies/rollback.\n"
            "- Keep scope aligned to goal and constraints.\n"
        ),
        "writing": (
            "Repair policy for writing tasks:\n"
            "- Match requested format exactly.\n"
            "- Preserve factual constraints.\n"
            "- Keep concise.\n"
        ),
    }
    return policies.get(route, policies["writing"])


def build_repair_prompt(req: Dict[str, Any], route: str, previous_response: str, verification: Dict[str, Any]) -> str:
    missing_checks = verification.get("checks_missing", [])
    route_failures = verification.get("route_failures", [])
    tool_failures = verification.get("tool_failures", [])
    regex_missing = verification.get("regex_missing", [])
    regex_forbidden_hits = verification.get("regex_forbidden_hits", [])
    missing_block = "\n".join(f"- {m}" for m in missing_checks) if missing_checks else "- <none>"
    route_block = "\n".join(f"- {f}" for f in route_failures) if route_failures else "- <none>"
    tool_block = "\n".join(f"- {f}" for f in tool_failures) if tool_failures else "- <none>"
    regex_missing_block = "\n".join(f"- {f}" for f in regex_missing) if regex_missing else "- <none>"
    regex_forbidden_block = "\n".join(f"- {f}" for f in regex_forbidden_hits) if regex_forbidden_hits else "- <none>"
    return (
        "Repair the previous answer so it passes all checks.\n"
        "Do not explain the repair process.\n"
        "Return only the corrected final answer.\n\n"
        f"{_repair_policy(route)}\n"
        f"Goal:\n{req['goal']}\n\n"
        f"Constraints:\n" + "\n".join(f"- {c}" for c in req.get("constraints", [])) + "\n\n"
        f"Required output format:\n{req['output_format']}\n\n"
        "Acceptance checks that failed:\n"
        f"{missing_block}\n\n"
        "Route failures:\n"
        f"{route_block}\n\n"
        "Tool-check failures:\n"
        f"{tool_block}\n\n"
        "Required regex patterns still missing (must be included):\n"
        f"{regex_missing_block}\n\n"
        "Forbidden regex patterns currently present (must be removed):\n"
        f"{regex_forbidden_block}\n\n"
        "Previous answer:\n"
        f"{previous_response}\n"
    )


def post_chat(endpoint: str, system_prompt: str, user_prompt: str, timeout_s: int = 120) -> Dict[str, Any]:
    payload = {
        "model": "local",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.0,
        "top_p": 1.0,
        "top_k": 1,
        "seed": 42,
        "max_tokens": 420,
    }
    req = urllib.request.Request(
        endpoint.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        return json.loads(resp.read().decode("utf-8"))


def extract_text(resp: Dict[str, Any]) -> str:
    msg = ((resp.get("choices") or [{}])[0]).get("message", {})
    return (msg.get("content") or msg.get("reasoning_content") or "").strip()


def append_jsonl(path: Path, record: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=True) + "\n")


def run_structured_request(
    raw: Dict[str, Any],
    server: str,
    no_verify: bool,
    max_retries: int,
    log_file: str,
) -> Dict[str, Any]:
    errors = validate_request(raw)
    if errors:
        return {"ok": False, "errors": errors}

    task_type = raw.get("task_type", "auto")
    if task_type == "auto":
        task_type = classify_task(raw["goal"])

    base_dir = Path(__file__).resolve().parent
    system_prompt = load_template(task_type, base_dir)
    user_prompt = build_user_prompt(raw)

    started = time.time()
    attempts: List[Dict[str, Any]] = []
    try:
        resp = post_chat(server, system_prompt, user_prompt)
    except urllib.error.URLError as exc:
        return {"ok": False, "error": f"server request failed: {exc}"}

    response_text = extract_text(resp)
    timings = resp.get("timings", {})
    verification = None if no_verify else verify_response(raw, task_type, response_text)
    attempts.append(
        {
            "attempt": 1,
            "kind": "initial",
            "response": response_text,
            "timings": timings,
            "verification": verification,
        }
    )

    retries_done = 0
    while (
        not no_verify
        and verification is not None
        and not verification["passed"]
        and retries_done < max(0, max_retries)
    ):
        retries_done += 1
        repair_prompt = build_repair_prompt(raw, task_type, response_text, verification)
        try:
            resp = post_chat(server, system_prompt, repair_prompt)
        except urllib.error.URLError as exc:
            return {"ok": False, "error": f"repair request failed: {exc}"}
        response_text = extract_text(resp)
        timings = resp.get("timings", {})
        verification = verify_response(raw, task_type, response_text)
        attempts.append(
            {
                "attempt": 1 + retries_done,
                "kind": "repair",
                "response": response_text,
                "timings": timings,
                "verification": verification,
            }
        )

    elapsed_ms = int((time.time() - started) * 1000)
    log_path = Path(log_file)
    if not log_path.is_absolute():
        log_path = base_dir / log_path

    run_record = {
        "ts_unix": int(time.time()),
        "route": task_type,
        "goal": raw["goal"],
        "output_format": raw["output_format"],
        "acceptance_checks": raw["acceptance_checks"],
        "response": response_text,
        "timings": timings,
        "elapsed_ms": elapsed_ms,
        "verification": verification,
        "attempts": attempts,
    }
    append_jsonl(log_path, run_record)

    out: Dict[str, Any] = {
        "ok": True,
        "route": task_type,
        "normalized_request": raw,
        "response": response_text,
        "elapsed_ms": elapsed_ms,
        "timings": timings,
        "log_file": str(log_path),
        "attempts_used": 1 + retries_done,
        "attempts": attempts,
    }
    if verification is not None:
        out["verification"] = verification
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Structured local router for deeply-tuned server")
    parser.add_argument("--request-file", help="Path to request JSON file")
    parser.add_argument("--request-json", help="Inline request JSON string")
    parser.add_argument("--server", default=os.getenv("ROUTER_SERVER_URL", "http://127.0.0.1:8080"))
    parser.add_argument("--dry-run", action="store_true", help="Only show normalized route and prompt")
    parser.add_argument("--log-file", default="logs/router_runs.jsonl")
    parser.add_argument("--no-verify", action="store_true", help="Skip verifier gates")
    parser.add_argument("--fail-on-verify", action="store_true", help="Exit non-zero if verifier fails")
    parser.add_argument("--max-retries", type=int, default=1, help="Repair retries after verifier failure")
    args = parser.parse_args()

    if not args.request_file and not args.request_json:
        print("provide --request-file or --request-json", file=sys.stderr)
        return 2
    if args.request_file and args.request_json:
        print("use only one of --request-file or --request-json", file=sys.stderr)
        return 2

    if args.request_file:
        raw = load_json(Path(args.request_file))
    else:
        raw = json.loads(args.request_json)

    errors = validate_request(raw)
    if errors:
        print(json.dumps({"ok": False, "errors": errors}, indent=2))
        return 1

    task_type = raw.get("task_type", "auto")
    if task_type == "auto":
        task_type = classify_task(raw["goal"])

    base_dir = Path(__file__).resolve().parent
    system_prompt = load_template(task_type, base_dir)
    user_prompt = build_user_prompt(raw)

    out: Dict[str, Any] = {
        "ok": True,
        "route": task_type,
        "normalized_request": raw,
    }
    if args.dry_run:
        out["system_prompt"] = system_prompt
        out["user_prompt"] = user_prompt
        print(json.dumps(out, indent=2))
        return 0

    result = run_structured_request(
        raw=raw,
        server=args.server,
        no_verify=args.no_verify,
        max_retries=args.max_retries,
        log_file=args.log_file,
    )
    if not result.get("ok", False):
        print(json.dumps(result, indent=2))
        return 1

    out.update(
        {
            "response": result["response"],
            "elapsed_ms": result["elapsed_ms"],
            "timings": result["timings"],
            "log_file": result["log_file"],
            "attempts_used": result["attempts_used"],
        }
    )
    if "verification" in result:
        out["verification"] = result["verification"]
    out["attempts"] = result["attempts"]
    print(json.dumps(out, indent=2))
    if (
        "verification" in result
        and args.fail_on_verify
        and not result["verification"]["passed"]
    ):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
