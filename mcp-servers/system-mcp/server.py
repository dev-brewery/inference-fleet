"""MCP tool server for system status and monitoring."""
import json
import os
import shutil
import subprocess
import urllib.request

from fastmcp import FastMCP
from starlette.responses import JSONResponse

PROXY_URL = os.environ.get("PROXY_URL", "http://localhost:4000")
PORT = int(os.environ.get("MCP_PORT", "8095"))

mcp = FastMCP("system-mcp")


@mcp.custom_route("/health", methods=["GET"])
async def health(request):
    return JSONResponse({"status": "ok"})


@mcp.tool
def gpu_status() -> dict:
    """Get NVIDIA GPU status (utilization, memory, temperature) via nvidia-smi."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        gpus = []
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = [p.strip() for p in line.split(",")]
            gpus.append({
                "index": int(parts[0]),
                "name": parts[1],
                "utilization_pct": int(parts[2]),
                "memory_used_mb": int(parts[3]),
                "memory_total_mb": int(parts[4]),
                "temperature_c": int(parts[5]),
            })
        return {"gpus": gpus}
    except FileNotFoundError:
        return {"error": "nvidia-smi not found"}
    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def containers() -> list[dict]:
    """List running Docker containers with status and resource usage."""
    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"],
            capture_output=True, text=True, timeout=10,
        )
        containers = []
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split("\t")
            containers.append({
                "name": parts[0],
                "status": parts[1] if len(parts) > 1 else "",
                "image": parts[2] if len(parts) > 2 else "",
                "ports": parts[3] if len(parts) > 3 else "",
            })
        return containers
    except Exception as e:
        return [{"error": str(e)}]


@mcp.tool
def disk_usage() -> dict:
    """Get disk usage for key paths: /, /storage, /storage/models."""
    paths = ["/", "/storage", "/storage/models"]
    result = {}
    for path in paths:
        try:
            usage = shutil.disk_usage(path)
            result[path] = {
                "total_gb": round(usage.total / (1024**3), 1),
                "used_gb": round(usage.used / (1024**3), 1),
                "free_gb": round(usage.free / (1024**3), 1),
                "used_pct": round(usage.used / usage.total * 100, 1),
            }
        except Exception as e:
            result[path] = {"error": str(e)}
    return result


@mcp.tool
def proxy_health() -> dict:
    """Get smart proxy status including active model, swap state, and model list."""
    status = {}
    try:
        req = urllib.request.Request(f"{PROXY_URL}/v1/status")
        with urllib.request.urlopen(req, timeout=5) as resp:
            status["proxy"] = json.loads(resp.read())
    except Exception as e:
        status["proxy"] = {"error": str(e)}

    try:
        req = urllib.request.Request(f"{PROXY_URL}/v1/models")
        with urllib.request.urlopen(req, timeout=5) as resp:
            models = json.loads(resp.read())
            status["models"] = [
                {"id": m["id"], "available": m.get("available", False)}
                for m in models.get("data", [])
            ]
    except Exception as e:
        status["models"] = {"error": str(e)}

    return status


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=PORT)
