#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONTAINER_NAME="${CONTAINER_NAME:-deeply-tuned-server}"
PORT="${SERVER_PORT:-8080}"

echo "[reload] stopping existing container (if running): ${CONTAINER_NAME}"
docker compose rm -s -f deeply-tuned-ai >/dev/null 2>&1 || true

echo "[reload] starting container with current .env profile"
docker compose up -d deeply-tuned-ai

echo "[reload] waiting for health endpoint on :${PORT}"
for _ in {1..120}; do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
    echo "[reload] healthy"
    docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | rg "^${CONTAINER_NAME}\b" || true
    exit 0
  fi
  sleep 2
done

echo "[reload] server did not become healthy in time"
docker logs --tail 120 "${CONTAINER_NAME}" || true
exit 1
