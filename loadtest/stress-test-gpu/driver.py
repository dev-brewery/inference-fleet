#!/usr/bin/env python3
"""
Stress-test driver: hammers 8 llama-server backends (4 per GPU) with
prefill-heavy requests to drive both P40s toward TDP.

- :8080/health          200 when all backends healthy AND hammer running
- :8080/v1/models       minimal listing for smart-proxy compatibility
- :8080/stats           per-backend RPS / latency / errors
- :8080/gpu-stats       aggregate stats per GPU (0 vs 1)
- :8080/metrics         relays all backends' /metrics with backend labels
- :8080/start /stop     pause/resume hammer threads
"""
import json
import os
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 8 backends: 4 on GPU 0, 4 on GPU 1
BACKENDS = {}
for suffix in ['0A', '0B', '0C', '0D', '1A', '1B', '1C', '1D']:
    env_key = f"BACKEND_{suffix}"
    default = f"http://stress-{suffix.lower()}:8080"
    BACKENDS[suffix.lower()] = os.environ.get(env_key, default)

WORKERS = int(os.environ.get("WORKERS_PER_BACKEND", "8"))
PREFILL_TOKENS = int(os.environ.get("PREFILL_TOKENS", "1500"))
MAX_OUTPUT = int(os.environ.get("MAX_OUTPUT_TOKENS", "32"))
AUTOSTART = os.environ.get("AUTOSTART", "1") == "1"

# Technical filler for prefill load
_FILLERS = [
    "The Pascal architecture GP102 die used on the Tesla P40 has 3,840 CUDA cores arranged in 30 SMs, each with 128 ALUs. Unlike later architectures, it has no Tensor Cores, so Flash Attention offers no benefit. ",
    "For quantized inference the dominant cost is dequantization plus the subsequent matmul. With GGML_CUDA_FORCE_MMQ=1 the INT8 multiply-and-accumulate kernels run at roughly 47 TOPS on a P40. ",
    "Row-split tensor parallelism splits each matmul in half across two GPUs: both cards compute their half of every layer and merge via PCIe on each forward pass. ",
    "KV cache size per token is 2 * n_layers * n_kv_heads * head_dim bytes at f16. For Qwen3-4B with 36 layers and 8 kv-heads, a single token costs 144 KB of KV cache. ",
    "Thermal throttling on the P40 begins around 88 C. A P40 holding 220 W continuously will plateau at an equilibrium temperature depending on chassis airflow. ",
    "Prefill is compute-bound while decode is memory-bandwidth-bound. A request with many input tokens and few output tokens spends most time in prefill, saturating the INT8 ALUs. ",
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
    return "".join(chunks) + "\n\nSummarize in one sentence."


def backend_health(base_url: str) -> bool:
    try:
        with urllib.request.urlopen(base_url + "/health", timeout=3) as resp:
            return resp.status == 200
    except Exception:
        return False


def fire_request(backend_label: str, base_url: str, prompt: str) -> tuple[bool, float]:
    url = base_url + "/v1/chat/completions"
    body = json.dumps({
        "model": "stress",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_OUTPUT,
        "temperature": 0.7,
        "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
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
    i = worker_id * 17  # offset to vary prompts
    print(f"[hammer] {backend_label}#{worker_id} started -> {base_url}", flush=True)
    while True:
        with state_lock:
            running = state["running"]
        if not running:
            time.sleep(0.25)
            continue
        prompt = build_prompt(i)
        ok, dt = fire_request(backend_label, base_url, prompt)
        # Log every 10th request from worker 0
        total = state["stats"][backend_label]["ok"] + state["stats"][backend_label]["err"]
        if worker_id == 0 and total % 10 == 0:
            print(f"[hammer] {backend_label} ok={ok} lat={dt:.2f}s total={total}", flush=True)
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
    print(f"[driver] hammer threads launched: {len(worker_threads)} total ({WORKERS} per backend × {len(BACKENDS)} backends)", flush=True)


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

        if self.path == "/v1/models":
            return self._json(200, {"object": "list", "data": [{"id": "stress-test", "object": "model", "owned_by": "local"}]})

        if self.path == "/stats":
            with state_lock:
                elapsed = time.time() - state["started_at"] if state["started_at"] else 0
                out = {
                    "elapsed_s": round(elapsed, 1),
                    "running": state["running"],
                    "workers_per_backend": WORKERS,
                    "total_workers": WORKERS * len(BACKENDS),
                    "prefill_tokens": PREFILL_TOKENS,
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

        if self.path == "/gpu-stats":
            with state_lock:
                elapsed = time.time() - state["started_at"] if state["started_at"] else 0
                gpu0 = {"ok": 0, "err": 0, "lat_sum": 0.0}
                gpu1 = {"ok": 0, "err": 0, "lat_sum": 0.0}
                for k, s in state["stats"].items():
                    target = gpu0 if k.startswith("0") else gpu1
                    target["ok"] += s["ok"]
                    target["err"] += s["err"]
                    target["lat_sum"] += s["lat_sum"]
                out = {"elapsed_s": round(elapsed, 1), "running": state["running"]}
                for name, g in [("gpu0", gpu0), ("gpu1", gpu1)]:
                    total = g["ok"] + g["err"]
                    out[name] = {
                        "ok": g["ok"],
                        "err": g["err"],
                        "rps": round(total / elapsed, 3) if elapsed > 0 else 0,
                        "mean_lat_s": round(g["lat_sum"] / g["ok"], 2) if g["ok"] else None,
                    }
            return self._json(200, out)

        if self.path == "/metrics":
            lines = [f"# stress-driver relay for {len(BACKENDS)} backends"]
            for label, base in BACKENDS.items():
                gpu = "gpu0" if label.startswith("0") else "gpu1"
                try:
                    with urllib.request.urlopen(base + "/metrics", timeout=3) as r:
                        body = r.read().decode("utf-8", "replace")
                    for raw in body.splitlines():
                        if not raw or raw.startswith("#"):
                            lines.append(raw)
                            continue
                        if "{" in raw:
                            name, rest = raw.split("{", 1)
                            lines.append(f'{name}{{backend="{label}",gpu="{gpu}",{rest}')
                        else:
                            parts = raw.split(" ", 1)
                            if len(parts) == 2:
                                lines.append(f'{parts[0]}{{backend="{label}",gpu="{gpu}"}} {parts[1]}')
                            else:
                                lines.append(raw)
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

        return self._json(503, {"error": "stress-test stack — not for inference", "endpoints": ["/health", "/stats", "/gpu-stats", "/metrics", "/start", "/stop"]})

    def do_POST(self):
        return self._json(503, {"error": "stress-test stack does not serve inference"})


def wait_for_backends():
    while True:
        ready = {k: backend_health(v) for k, v in BACKENDS.items()}
        healthy = sum(ready.values())
        if healthy == len(BACKENDS):
            print(f"[driver] all {len(BACKENDS)} backends healthy", flush=True)
            return
        print(f"[driver] waiting: {healthy}/{len(BACKENDS)} healthy — {ready}", flush=True)
        time.sleep(5)


def main():
    host, port = "0.0.0.0", 8080
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"[driver] listening on {host}:{port}", flush=True)
    print(f"[driver] backends: {list(BACKENDS.keys())}", flush=True)
    print(f"[driver] config: {WORKERS} workers/backend × {len(BACKENDS)} backends = {WORKERS * len(BACKENDS)} total workers", flush=True)
    print(f"[driver] prefill={PREFILL_TOKENS} tokens, max_output={MAX_OUTPUT} tokens", flush=True)

    if AUTOSTART:
        def _boot():
            wait_for_backends()
            start_hammer()
        threading.Thread(target=_boot, daemon=True, name="bootstrap").start()

    server.serve_forever()


if __name__ == "__main__":
    main()
