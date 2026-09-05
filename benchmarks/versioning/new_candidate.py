#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List


ROOT = Path(__file__).resolve().parents[1]
VROOT = ROOT / "versioning"
CDIR = VROOT / "candidates"
LEDGER = VROOT / "ledger.jsonl"

TRACKED_FILES = [
    ".env",
    "profiles/production.env",
    "start.sh",
    "docker-compose.yml",
    "README.md",
    "IMPLEMENTATION_PLAN.md",
    "EXECUTION_CHECKLIST.md",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def safe_label(label: str) -> str:
    out = re.sub(r"[^a-zA-Z0-9._-]+", "-", label.strip()).strip("-")
    return out or "candidate"


def run_cmd(cmd: List[str], timeout: int = 20) -> Dict[str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=str(ROOT))
        return {"cmd": " ".join(cmd), "rc": str(p.returncode), "stdout": p.stdout.strip(), "stderr": p.stderr.strip()}
    except Exception as exc:
        return {"cmd": " ".join(cmd), "rc": "error", "stdout": "", "stderr": str(exc)}


def append_ledger(record: Dict) -> None:
    VROOT.mkdir(parents=True, exist_ok=True)
    with LEDGER.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Create immutable deeply-tuned candidate snapshot")
    parser.add_argument("label", help="short candidate label")
    parser.add_argument("notes", nargs="?", default="", help="optional notes")
    args = parser.parse_args()

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    cid = f"{ts}_{safe_label(args.label)}"
    candidate_dir = CDIR / cid
    snapshot_dir = candidate_dir / "snapshot"
    snapshot_dir.mkdir(parents=True, exist_ok=False)

    file_hashes = {}
    copied = []
    missing = []
    for rel in TRACKED_FILES:
        src = ROOT / rel
        if src.exists() and src.is_file():
            dst = snapshot_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            file_hashes[rel] = sha256_file(src)
            copied.append(rel)
        else:
            missing.append(rel)

    diagnostics = {
        "date_utc": run_cmd(["date", "-u"]),
        "docker_ps": run_cmd(["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"], timeout=30),
        "nvidia_smi": run_cmd(
            ["nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.free,power.draw", "--format=csv,noheader"],
            timeout=30,
        ),
    }

    meta = {
        "candidate_id": cid,
        "created_utc": ts,
        "label": args.label,
        "notes": args.notes,
        "root": str(ROOT),
        "tracked_files": copied,
        "missing_files": missing,
        "file_hashes": file_hashes,
        "diagnostics": diagnostics,
        "status": "created",
        "evaluation": None,
    }
    (candidate_dir / "metadata.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

    append_ledger({"ts_utc": ts, "event": "candidate_created", "candidate_id": cid, "label": args.label})
    print(cid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
