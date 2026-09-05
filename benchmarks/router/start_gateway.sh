#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

HOST="${GATEWAY_HOST:-0.0.0.0}"
PORT="${GATEWAY_PORT:-8090}"
LLM_SERVER="${LLM_SERVER_URL:-http://127.0.0.1:8080}"
MAX_RETRIES="${GATEWAY_MAX_RETRIES:-2}"

exec python3 ./gateway.py \
  --host "${HOST}" \
  --port "${PORT}" \
  --llm-server "${LLM_SERVER}" \
  --max-retries "${MAX_RETRIES}" \
  --fail-on-verify
