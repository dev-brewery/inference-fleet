#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List


ROOT = Path(__file__).resolve().parents[1]
VROOT = ROOT / "versioning"
CDIR = VROOT / "candidates"
GATES = VROOT / "gates.json"
LEDGER = VROOT / "ledger.jsonl"


def append_ledger(record: Dict) -> None:
    with LEDGER.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=True) + "\n")


def read_json(path: Path) -> Dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate candidate against gates")
    parser.add_argument("candidate_id")
    parser.add_argument("metrics_json", help="path to metrics json")
    args = parser.parse_args()

    cdir = CDIR / args.candidate_id
    meta_path = cdir / "metadata.json"
    if not meta_path.exists():
        raise SystemExit(f"candidate not found: {args.candidate_id}")
    metrics_path = Path(args.metrics_json).resolve()
    if not metrics_path.exists():
        raise SystemExit(f"metrics file not found: {metrics_path}")

    gates = read_json(GATES)
    meta = read_json(meta_path)
    metrics = read_json(metrics_path)

    failures: List[str] = []
    evidence: Dict = {}

    report_path_str = str(metrics.get("openwebui_report_path", "")).strip()
    if not report_path_str:
        failures.append("openwebui_report_path missing in metrics")
    else:
        report_path = Path(report_path_str).expanduser().resolve()
        if not report_path.exists():
            failures.append(f"openwebui report not found: {report_path}")
        else:
            try:
                report = read_json(report_path)
                passed = int(report.get("passed", 0))
                total = int(report.get("total", 0))
                report_success = total > 0 and passed == total
                evidence = {
                    "openwebui_report_path": str(report_path),
                    "openwebui_report_passed": passed,
                    "openwebui_report_total": total,
                    "openwebui_report_all_passed": report_success,
                }
                if not report_success:
                    failures.append("openwebui report indicates failing tests")
                if bool(metrics.get("openwebui_tests_passed", False)) != report_success:
                    failures.append("openwebui_tests_passed does not match report summary")
            except Exception as exc:
                failures.append(f"failed to parse openwebui report: {exc}")

    if bool(metrics.get("openwebui_tests_passed", False)) != bool(gates["openwebui_tests_passed"]):
        failures.append("openwebui_tests_passed gate failed")
    if float(metrics.get("stream_success_rate", 0.0)) < float(gates["stream_success_rate_min"]):
        failures.append("stream_success_rate gate failed")
    if float(metrics.get("real_requests_pass_at_2", 0.0)) < float(gates["real_requests_pass_at_2_min"]):
        failures.append("real_requests_pass_at_2 gate failed")
    if float(metrics.get("gen_tps", 0.0)) < float(gates["gen_tps_min"]):
        failures.append("gen_tps gate failed")

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    status = "pass" if not failures else "fail"
    evaluation = {
        "evaluated_utc": ts,
        "status": status,
        "metrics_path": str(metrics_path),
        "metrics": metrics,
        "evidence": evidence,
        "gates": gates,
        "failures": failures,
    }
    meta["status"] = status
    meta["evaluation"] = evaluation
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")

    append_ledger(
        {
            "ts_utc": ts,
            "event": "candidate_evaluated",
            "candidate_id": args.candidate_id,
            "status": status,
            "failures": failures,
        }
    )

    print(status)
    if failures:
        for f in failures:
            print(f"- {f}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
