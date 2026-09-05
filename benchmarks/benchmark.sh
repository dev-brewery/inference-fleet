#!/usr/bin/env bash
set -euo pipefail

PORT="${SERVER_PORT:-8080}"
PROMPT="${1:-Write a concise architecture plan for a reliable distributed job queue.}"

echo "[bench] waiting for server on :${PORT} ..."
for _ in {1..60}; do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
        break
    fi
    sleep 2
done

if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
    echo "[bench] server is not healthy"
    exit 1
fi

echo "[bench] one-shot generation test"
curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"local\",
    \"messages\": [{\"role\": \"user\", \"content\": \"${PROMPT}\"}],
    \"max_tokens\": 256,
    \"temperature\": 0.2
  }" | sed -n '1,140p'

echo
echo "[bench] gpu snapshot"
nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu,power.draw --format=csv,noheader

