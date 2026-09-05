#!/usr/bin/env python3
"""
Stress-test driver for qwen3-concurrency: hammers 2 backends (one per GPU)
with prefill-heavy requests to drive both P40s toward TDP.

Endpoints:
  /health      200 when both backends healthy AND hammer running
  /stats       per-backend and aggregate stats
  /metrics     relay backend /metrics with labels
  /start       resume hammer
  /stop        pause hammer
"""
import json
import os
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKENDS = {
    "gpu0": os.environ.get("BACKEND_0", "http://qwen3-gpu0:8080"),
    "gpu1": os.environ.get("BACKEND_1", "http://qwen3-gpu1:8080"),
}

WORKERS = int(os.environ.get("WORKERS_PER_BACKEND", "6"))
PREFILL_TOKENS = int(os.environ.get("PREFILL_TOKENS", "800"))
MAX_OUTPUT = int(os.environ.get("MAX_OUTPUT_TOKENS", "64"))
AUTOSTART = os.environ.get("AUTOSTART", "1") == "1"

_FILLERS = [
    "The Pascal architecture GP102 die used on the Tesla P40 has 3,840 CUDA cores arranged in 30 SMs, each with 128 ALUs. Unlike later architectures, it has no Tensor Cores, so Flash Attention offers no benefit and in fact hurts throughput. ",
    "For quantized inference the dominant cost is dequantization plus the subsequent matmul. With GGML_CUDA_FORCE_MMQ=1 the INT8 multiply-and-accumulate kernels run at roughly 47 TOPS on a P40. ",
    "Row-split tensor parallelism splits each matmul in half across two GPUs: both cards compute their half of every layer and merge via PCIe on each forward pass. ",
    "KV cache size per token is 2 * n_layers * n_kv_heads * head_dim bytes at f16. For a 30B model with 64 layers and 8 kv-heads, a single token costs 256 KB of KV cache. ",
    "Thermal throttling on the P40 begins around 88 C. A P40 holding 220 W continuously will plateau at an equilibrium temperature depending on chassis airflow. ",
    "Prefill is compute-bound while decode is memory-bandwidth-bound. Dense models use all parameters every forward pass, maximizing ALU utilization during prefill. ",
]

state_lock = threading.Lock()
state = {
    "running": False,
    "started_at": None,
    "stats": {label: {"ok": 0, "err": 0, "lat_sum": 0.0, "lat_max": 0.0} for label in BACKENDS},
}
worker_threads = []


def build_prompt(idx: int) -> str:
    target_chars = int(PREFILL_TOKENS * 3.5)
    chunks = []
    total = 0
    i = idx
    while total < target_chars:
        f = _FILLERS[i % len(_FILLERS)]
        chunks.append(f)
        total += len(f)
        i += 1
    return "".join(chunks) + "\n\nProvide a detailed technical summary of the above."


def backend_health(base_url: str) -> bool:
    try:
        with urllib.request.urlopen(base_url + "/health", timeout=5) as resp:
            return resp.status == 200
    except Exception:
        return False


def fire_request(backend_label: str, base_url: str, prompt: str) -> tuple[bool, float]:
    url = base_url + "/v1/chat/completions"
    body = json.dumps({
        "model": "qwen3-30b",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_OUTPUT,
        "temperature": 0.7,
        "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            resp.read()
            ok = 200 <= resp.status < 300
    except Exception as e:
        print(f"[hammer] {backend_label} error: {e}", flush=True)
        ok = False
    dt = time.monotonic() - t0
    with state_lock:
        s = state["stats"][backend_label]
        if ok:
            s["ok"] += 1
            s["lat_sum"] += dt
            if dt > s["lat_max"]:
                s["lat_max"] = dt
        else:
            s["err"] += 1
    return ok, dt


def worker_loop(backend_label: str, base_url: str, worker_id: int):
    i = worker_id * 17
    print(f"[hammer] {backend_label}#{worker_id} started -> {base_url}", flush=True)
    while True:
        with state_lock:
            running = state["running"]
        if not running:
            time.sleep(0.25)
            continue
        prompt = build_prompt(i)
        ok, dt = fire_request(backend_label, base_url, prompt)
        total = state["stats"][backend_label]["ok"] + state["stats"][backend_label]["err"]
        if worker_id == 0 and total % 5 == 0:
            print(f"[hammer] {backend_label} ok={ok} lat={dt:.1f}s total={total}", flush=True)
        i += 1


def start_hammer():
    with state_lock:
        if state["running"]:
            return
        state["running"] = True
        state["started_at"] = time.time()
    if worker_threads:
        return
    for label, base_url in BACKENDS.items():
        for w in range(WORKERS):
            t = threading.Thread(target=worker_loop, args=(label, base_url, w), daemon=True, name=f"hammer-{label}-{w}")
            t.start()
            worker_threads.append(t)
    print(f"[driver] hammer started: {len(worker_threads)} workers ({WORKERS}/backend)", flush=True)


def stop_hammer():
    with state_lock:
        state["running"] = False
    print("[driver] hammer paused", flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _json(self, code: int, payload):
        data = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            backend_status = {k: backend_health(v) for k, v in BACKENDS.items()}
            all_ok = all(backend_status.values())
            with state_lock:
                running = state["running"]
            return self._json(200 if (all_ok and running) else 503, {
                "status": "ok" if (all_ok and running) else "starting",
                "backends": backend_status,
                "hammer_running": running,
            })

        if self.path == "/stats":
            with state_lock:
                elapsed = time.time() - state["started_at"] if state["started_at"] else 0
                total_ok = sum(s["ok"] for s in state["stats"].values())
                total_err = sum(s["err"] for s in state["stats"].values())
                out = {
                    "elapsed_s": round(elapsed, 1),
                    "running": state["running"],
                    "config": {
                        "workers_per_backend": WORKERS,
                        "prefill_tokens": PREFILL_TOKENS,
                        "max_output": MAX_OUTPUT,
                    },
                    "aggregate": {
                        "ok": total_ok,
                        "err": total_err,
                        "rps": round((total_ok + total_err) / elapsed, 3) if elapsed > 0 else 0,
                    },
                    "backends": {},
                }
                for k, s in state["stats"].items():
                    total = s["ok"] + s["err"]
                    out["backends"][k] = {
                        "ok": s["ok"],
                        "err": s["err"],
                        "rps": round(total / elapsed, 3) if elapsed > 0 else 0,
                        "mean_lat_s": round(s["lat_sum"] / s["ok"], 2) if s["ok"] else None,
                        "max_lat_s": round(s["lat_max"], 2),
                    }
            return self._json(200, out)

        if self.path == "/metrics":
            lines = ["# qwen3-concurrency driver metrics"]
            for label, base in BACKENDS.items():
                try:
                    with urllib.request.urlopen(base + "/metrics", timeout=3) as r:
                        body = r.read().decode("utf-8", "replace")
                    for raw in body.splitlines():
                        if not raw or raw.startswith("#"):
                            continue
                        if "{" in raw:
                            name, rest = raw.split("{", 1)
                            lines.append(f'{name}{{backend="{label}",{rest}')
                        else:
                            parts = raw.split(" ", 1)
                            if len(parts) == 2:
                                lines.append(f'{parts[0]}{{backend="{label}"}} {parts[1]}')
                except Exception as e:
                    lines.append(f"# {label} unreachable: {e}")
            body = ("\n".join(lines) + "\n").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/start":
            start_hammer()
            return self._json(200, {"status": "running"})

        if self.path == "/stop":
            stop_hammer()
            return self._json(200, {"status": "paused"})

        return self._json(404, {"error": "not found", "endpoints": ["/health", "/stats", "/metrics", "/start", "/stop"]})

    def do_POST(self):
        return self._json(503, {"error": "this stack is for stress testing, not inference"})


def wait_for_backends():
    while True:
        ready = {k: backend_health(v) for k, v in BACKENDS.items()}
        if all(ready.values()):
            print(f"[driver] all backends healthy", flush=True)
            return
        print(f"[driver] waiting: {ready}", flush=True)
        time.sleep(5)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    print(f"[driver] qwen3-concurrency stress driver", flush=True)
    print(f"[driver] backends: {list(BACKENDS.keys())}", flush=True)
    print(f"[driver] {WORKERS} workers/backend, {PREFILL_TOKENS} prefill tokens", flush=True)

    if AUTOSTART:
        threading.Thread(target=lambda: (wait_for_backends(), start_hammer()), daemon=True).start()

    server.serve_forever()


if __name__ == "__main__":
    main()
