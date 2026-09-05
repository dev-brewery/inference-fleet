#!/usr/bin/env python3
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


@dataclass
class TestResult:
    name: str
    passed: bool
    detail: str
    duration_ms: int
    meta: Dict[str, Any]


def now_ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def env_required(name: str) -> str:
    v = os.getenv(name, "").strip()
    if not v:
        raise RuntimeError(f"Missing required env var: {name}")
    return v


def request_json(
    method: str,
    url: str,
    token: Optional[str] = None,
    payload: Optional[Dict[str, Any]] = None,
    timeout_s: int = 60,
) -> Tuple[int, Dict[str, Any]]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, method=method, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        body = resp.read().decode("utf-8")
        try:
            parsed = json.loads(body) if body else {}
        except json.JSONDecodeError:
            parsed = {"raw": body}
        return resp.status, parsed


def request_stream(
    url: str,
    token: Optional[str],
    payload: Dict[str, Any],
    timeout_s: int = 180,
) -> Tuple[int, str]:
    # Use curl for robust streaming with hard per-run max time, so a half-open stream
    # cannot block the full test suite.
    cmd = [
        "curl",
        "-N",
        "-sS",
        "--max-time",
        str(timeout_s),
        url,
        "-H",
        "Content-Type: application/json",
    ]
    if token:
        cmd.extend(["-H", f"Authorization: Bearer {token}"])
    cmd.extend(["-d", json.dumps(payload)])

    proc = subprocess.run(cmd, capture_output=True, text=True)
    out = proc.stdout or ""
    if proc.returncode != 0 and not out:
        raise RuntimeError(f"curl stream failed rc={proc.returncode}: {proc.stderr.strip()}")
    # curl may timeout mid-stream (rc 28) and still provide partial output; caller decides pass/fail.
    return 200 if out else 0, out


def detect_mode(base: str, token: str, timeout_s: int, forced: str) -> str:
    if forced in {"api", "openai"}:
        return forced

    candidates = [
        ("api", f"{base}/api/models"),
        ("openai", f"{base}/openai/models"),
    ]
    for mode, url in candidates:
        try:
            status, _ = request_json("GET", url, token=token, timeout_s=timeout_s)
            if status == 200:
                return mode
        except Exception:
            continue
    raise RuntimeError("Could not detect OpenWebUI API mode. Set OWUI_ENDPOINT_MODE=api or openai.")


def endpoint_paths(base: str, mode: str) -> Dict[str, str]:
    if mode == "api":
        return {
            "version": f"{base}/api/version",
            "models": f"{base}/api/models",
            "chat": f"{base}/api/chat/completions",
        }
    return {
        "version": f"{base}/api/version",
        "models": f"{base}/openai/models",
        "chat": f"{base}/openai/chat/completions",
    }


def run_test(name: str, fn) -> TestResult:
    t0 = time.time()
    try:
        detail, meta = fn()
        return TestResult(name=name, passed=True, detail=detail, duration_ms=int((time.time() - t0) * 1000), meta=meta)
    except Exception as exc:
        return TestResult(
            name=name,
            passed=False,
            detail=str(exc),
            duration_ms=int((time.time() - t0) * 1000),
            meta={},
        )


def main() -> int:
    base = env_required("OWUI_BASE_URL").rstrip("/")
    token = env_required("OWUI_API_KEY")
    model = env_required("OWUI_MODEL")
    stream_runs = int(os.getenv("OWUI_STREAM_RUNS", "20"))
    timeout_s = int(os.getenv("OWUI_TIMEOUT_S", "180"))
    out_dir = Path(os.getenv("OWUI_OUT_DIR", "./results"))
    forced_mode = os.getenv("OWUI_ENDPOINT_MODE", "auto").strip().lower()

    mode = detect_mode(base, token, timeout_s=timeout_s, forced=forced_mode)
    paths = endpoint_paths(base, mode)

    results: List[TestResult] = []

    def t_version():
        status, body = request_json("GET", paths["version"], token=token, timeout_s=timeout_s)
        if status != 200:
            raise RuntimeError(f"status={status}")
        version = str(body.get("version", "unknown"))
        return f"version={version}", {"status": status, "version": version}

    def t_models():
        status, body = request_json("GET", paths["models"], token=token, timeout_s=timeout_s)
        if status != 200:
            raise RuntimeError(f"status={status}")
        raw_models = body.get("data", body.get("models", []))
        if not isinstance(raw_models, list) or len(raw_models) == 0:
            raise RuntimeError("no models returned")
        names = []
        for m in raw_models[:10]:
            if isinstance(m, dict):
                names.append(str(m.get("id", m.get("name", "<unknown>"))))
        return f"models={len(raw_models)}", {"status": status, "sample_models": names}

    def t_non_stream():
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": "Reply with exactly: READY"}],
            "stream": False,
            "max_tokens": 32,
            "temperature": 0,
        }
        status, body = request_json("POST", paths["chat"], token=token, payload=payload, timeout_s=timeout_s)
        if status != 200:
            raise RuntimeError(f"status={status}, body={body}")
        choices = body.get("choices", [])
        if not isinstance(choices, list) or not choices:
            raise RuntimeError("no choices")
        msg = choices[0].get("message", {})
        text = str(msg.get("content", "")).strip()
        if not text:
            raise RuntimeError("empty assistant content")
        return "non-stream response received", {"status": status, "content": text[:120]}

    def t_stream_once():
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": "Write a short 6-item reliability checklist."}],
            "stream": True,
            "max_tokens": 180,
            "temperature": 0,
        }
        status, text = request_stream(paths["chat"], token=token, payload=payload, timeout_s=timeout_s)
        if status != 200:
            raise RuntimeError(f"status={status}")
        if "chat.completion.chunk" not in text:
            raise RuntimeError("missing chunk objects")
        if "data: [DONE]" not in text:
            raise RuntimeError("missing [DONE] sentinel")
        return "stream completed with [DONE]", {"status": status, "bytes": len(text)}

    def t_stream_stability():
        failures = []
        for i in range(1, stream_runs + 1):
            payload = {
                "model": model,
                "messages": [{"role": "user", "content": "Provide 10 concise bullets about service reliability."}],
                "stream": True,
                "max_tokens": 220,
                "temperature": 0,
            }
            try:
                status, text = request_stream(paths["chat"], token=token, payload=payload, timeout_s=timeout_s)
                ok = status == 200 and "chat.completion.chunk" in text and "data: [DONE]" in text
                if not ok:
                    failures.append({"run": i, "status": status, "has_done": "data: [DONE]" in text, "has_chunk": "chat.completion.chunk" in text})
            except Exception as exc:
                failures.append({"run": i, "error": str(exc)})
        if failures:
            raise RuntimeError(f"{len(failures)}/{stream_runs} stream failures: {failures[:3]}")
        return f"{stream_runs}/{stream_runs} stream runs stable", {"runs": stream_runs}

    def t_tools_roundtrip():
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": "Use tool calculator to compute 2+2."}],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": "calculator",
                        "description": "Compute arithmetic",
                        "parameters": {
                            "type": "object",
                            "properties": {"expr": {"type": "string"}},
                            "required": ["expr"],
                        },
                    },
                }
            ],
            "tool_choice": "auto",
            "stream": False,
            "max_tokens": 120,
            "temperature": 0,
        }
        status, body = request_json("POST", paths["chat"], token=token, payload=payload, timeout_s=timeout_s)
        if status != 200:
            raise RuntimeError(f"status={status}, body={body}")
        choices = body.get("choices", [])
        if not choices:
            raise RuntimeError("no choices")
        msg = choices[0].get("message", {})
        tool_calls = msg.get("tool_calls")
        if not isinstance(tool_calls, list) or len(tool_calls) == 0:
            raise RuntimeError(f"expected tool_calls, got: {msg}")
        fn = tool_calls[0].get("function", {})
        name = fn.get("name")
        args = fn.get("arguments")
        if name != "calculator":
            raise RuntimeError(f"unexpected tool name: {name}")
        return "tool_calls returned", {"tool_name": name, "arguments": args}

    def t_tool_follow_up():
        # first turn: get tool call
        payload_1 = {
            "model": model,
            "messages": [{"role": "user", "content": "Use tool calculator to compute 2+2 and answer."}],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": "calculator",
                        "description": "Compute arithmetic",
                        "parameters": {
                            "type": "object",
                            "properties": {"expr": {"type": "string"}},
                            "required": ["expr"],
                        },
                    },
                }
            ],
            "tool_choice": "auto",
            "stream": False,
            "max_tokens": 120,
            "temperature": 0,
        }
        _, body_1 = request_json("POST", paths["chat"], token=token, payload=payload_1, timeout_s=timeout_s)
        choice = body_1.get("choices", [{}])[0]
        msg = choice.get("message", {})
        tool_calls = msg.get("tool_calls", [])
        if not tool_calls:
            raise RuntimeError("first turn produced no tool_calls")
        tc = tool_calls[0]
        tc_id = tc.get("id")
        if not tc_id:
            raise RuntimeError("tool_call id missing")

        # second turn: send tool result
        payload_2 = {
            "model": model,
            "messages": [
                {"role": "user", "content": "Use tool calculator to compute 2+2 and answer."},
                msg,
                {"role": "tool", "tool_call_id": tc_id, "name": "calculator", "content": "4"},
            ],
            "tools": payload_1["tools"],
            "stream": False,
            "max_tokens": 120,
            "temperature": 0,
        }
        status2, body2 = request_json("POST", paths["chat"], token=token, payload=payload_2, timeout_s=timeout_s)
        if status2 != 200:
            raise RuntimeError(f"status={status2}, body={body2}")
        text = str(body2.get("choices", [{}])[0].get("message", {}).get("content", "")).strip()
        if not text:
            raise RuntimeError("empty final assistant answer")
        return "tool follow-up completed", {"final_answer": text[:160]}

    tests = [
        ("version", t_version),
        ("models", t_models),
        ("chat_non_stream", t_non_stream),
        ("chat_stream_once", t_stream_once),
        ("chat_stream_stability", t_stream_stability),
        ("tools_roundtrip", t_tools_roundtrip),
        ("tool_follow_up", t_tool_follow_up),
    ]

    for name, fn in tests:
        r = run_test(name, fn)
        results.append(r)
        status = "PASS" if r.passed else "FAIL"
        print(f"[{status}] {name} ({r.duration_ms} ms) - {r.detail}")

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    success_rate = (100.0 * passed / total) if total else 0.0
    summary = {
        "ts": now_ts(),
        "base_url": base,
        "mode": mode,
        "model": model,
        "passed": passed,
        "total": total,
        "success_rate": success_rate,
        "results": [asdict(r) for r in results],
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"openwebui_test_report_{summary['ts']}.json"
    out_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print()
    print(f"Summary: {passed}/{total} passed ({success_rate:.2f}%)")
    print(f"Report: {out_file}")

    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
