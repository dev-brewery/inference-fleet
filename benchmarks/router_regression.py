#!/usr/bin/env python3
import argparse
import csv
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Tuple


def map_task_type(expected_type: str) -> str:
    et = expected_type.lower()
    if et in {"sql", "command", "code", "review"}:
        return "code"
    if et in {"number", "logic"}:
        return "math_logic"
    if et in {"checklist", "security"}:
        return "ops"
    if et in {"architecture", "json"}:
        return "planning"
    return "writing"


def acceptance_checks(expected_type: str) -> List[str]:
    _ = expected_type
    # Keep acceptance checks intentionally broad in regression; deterministic regex gates
    # and route/tool verifiers carry the hard pass/fail signals.
    return ["Meets request requirements"]


def split_patterns(expr: str) -> List[str]:
    out: List[str] = []
    for p in expr.split("|"):
        s = p.strip()
        if s:
            out.append(s)
    return out


def output_format_from_type(expected_type: str) -> str:
    et = expected_type.lower()
    mapping = {
        "sql": "SQL query only",
        "command": "Single shell command",
        "code": "Code snippet",
        "review": "Concise code review comment",
        "number": "Short answer with final number",
        "logic": "Short logic explanation with final answer",
        "json": "Valid JSON object",
        "architecture": "Structured policy with bullet points",
        "checklist": "Action checklist",
        "security": "Containment and remediation checklist",
    }
    return mapping.get(et, "Concise response")


def regex_pass(response: str, required_regex: str, forbidden_regex: str) -> bool:
    for part in required_regex.split("|"):
        p = part.strip()
        if p and re.search(p, response, flags=re.IGNORECASE) is None:
            return False
    if forbidden_regex.strip() and re.search(forbidden_regex, response, flags=re.IGNORECASE):
        return False
    return True


def run_router(router_path: Path, req: Dict, server: str, max_retries: int) -> Dict:
    cmd = [
        "python3",
        str(router_path),
        "--request-json",
        json.dumps(req, ensure_ascii=True),
        "--server",
        server,
        "--max-retries",
        str(max_retries),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if not proc.stdout.strip():
        raise RuntimeError(f"router produced no stdout (rc={proc.returncode}): {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"failed to parse router output: {exc}\nstdout={proc.stdout}\nstderr={proc.stderr}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="Regression runner for structured router + verifier")
    parser.add_argument("--cases", default="./benchmark_cases_real.tsv")
    parser.add_argument("--router", default="./router/router.py")
    parser.add_argument("--server", default="http://127.0.0.1:8080")
    parser.add_argument("--max-retries", type=int, default=1)
    parser.add_argument("--out-dir", default="./bench-results")
    args = parser.parse_args()

    cases_path = Path(args.cases)
    router_path = Path(args.router)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = out_dir / f"router_regression_{ts}.tsv"

    rows: List[Tuple] = []
    total = 0
    init_pass = 0
    final_pass = 0
    regex_pass_count = 0
    repaired_improvements = 0

    with cases_path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            total += 1
            req = {
                "task_type": map_task_type(row["expected_type"]),
                "goal": row["user_request"],
                "constraints": ["Be concise", "Follow the required output format exactly"],
                "output_format": output_format_from_type(row["expected_type"]),
                "acceptance_checks": acceptance_checks(row["expected_type"]),
                "metadata": {
                    "required_patterns": split_patterns(row["required_regex"]),
                    "forbidden_patterns": split_patterns(row.get("forbidden_regex", "")),
                },
            }
            result = run_router(router_path, req, args.server, args.max_retries)
            attempts = result.get("attempts", [])
            initial_ver = (attempts[0] if attempts else {}).get("verification", {}) or {}
            final_ver = result.get("verification", {}) or {}

            initial_ok = bool(initial_ver.get("passed", False))
            final_ok = bool(final_ver.get("passed", False))
            if initial_ok:
                init_pass += 1
            if final_ok:
                final_pass += 1
            if (not initial_ok) and final_ok:
                repaired_improvements += 1

            response = result.get("response", "")
            regex_ok = regex_pass(response, row["required_regex"], row.get("forbidden_regex", ""))
            if regex_ok:
                regex_pass_count += 1

            attempts_used = int(result.get("attempts_used", 1))
            route = result.get("route", req["task_type"])
            rows.append(
                (
                    row["id"],
                    route,
                    attempts_used,
                    int(initial_ok),
                    int(final_ok),
                    int(regex_ok),
                    len(final_ver.get("checks_missing", [])) if isinstance(final_ver, dict) else -1,
                    ",".join(final_ver.get("route_failures", [])) if isinstance(final_ver, dict) else "",
                    ",".join(final_ver.get("tool_failures", [])) if isinstance(final_ver, dict) else "",
                    ",".join(final_ver.get("regex_missing", [])) if isinstance(final_ver, dict) else "",
                    ",".join(final_ver.get("regex_forbidden_hits", [])) if isinstance(final_ver, dict) else "",
                )
            )
            print(
                f"[regression] {row['id']}: route={route} attempts={attempts_used} "
                f"init={int(initial_ok)} final={int(final_ok)} regex={int(regex_ok)}"
            )

    with out_path.open("w", encoding="utf-8") as f:
        f.write(
            "id\troute\tattempts_used\tinitial_verify_pass\tfinal_verify_pass\tregex_pass\tchecks_missing_count\troute_failures\ttool_failures\tregex_missing\tregex_forbidden_hits\n"
        )
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")

    init_acc = (100.0 * init_pass / total) if total else 0.0
    final_acc = (100.0 * final_pass / total) if total else 0.0
    regex_acc = (100.0 * regex_pass_count / total) if total else 0.0
    delta = final_acc - init_acc

    print()
    print(
        f"total={total} initial_verify_pass={init_pass} ({init_acc:.2f}%) "
        f"final_verify_pass={final_pass} ({final_acc:.2f}%) delta={delta:.2f}pp "
        f"regex_pass={regex_pass_count} ({regex_acc:.2f}%) repaired_improvements={repaired_improvements}"
    )
    print(f"results={out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
