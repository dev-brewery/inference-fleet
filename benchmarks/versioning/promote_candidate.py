#!/usr/bin/env python3
import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict


ROOT = Path(__file__).resolve().parents[1]
VROOT = ROOT / "versioning"
CDIR = VROOT / "candidates"
RDIR = VROOT / "releases"
LEDGER = VROOT / "ledger.jsonl"
CURRENT = VROOT / "current_release.json"


def append_ledger(record: Dict) -> None:
    with LEDGER.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Promote passing candidate to release")
    parser.add_argument("candidate_id")
    args = parser.parse_args()

    cdir = CDIR / args.candidate_id
    meta_path = cdir / "metadata.json"
    if not meta_path.exists():
        raise SystemExit(f"candidate not found: {args.candidate_id}")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    if meta.get("status") != "pass":
        raise SystemExit(f"candidate is not pass (status={meta.get('status')})")

    rdir = RDIR / args.candidate_id
    if rdir.exists():
        raise SystemExit(f"release already exists: {rdir}")
    rdir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(cdir, rdir)

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    current = {
        "candidate_id": args.candidate_id,
        "promoted_utc": ts,
        "release_path": str(rdir),
    }
    CURRENT.write_text(json.dumps(current, indent=2), encoding="utf-8")
    append_ledger({"ts_utc": ts, "event": "candidate_promoted", "candidate_id": args.candidate_id})

    print(args.candidate_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
