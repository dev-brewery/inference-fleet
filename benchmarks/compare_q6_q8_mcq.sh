#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="${1:-./bench-results}"
mkdir -p "${OUT_DIR}"

run_model() {
  local label="$1"
  local model_root="$2"
  local model_file="$3"

  echo
  echo "[compare] ===== ${label} ====="
  MODEL_ROOT="${model_root}" \
  MODEL_FILE="${model_file}" \
  CHAT_TEMPLATE="" \
  REASONING_FORMAT="none" \
  REASONING_BUDGET="0" \
  docker compose up -d --force-recreate deeply-tuned-ai >/dev/null

  for _ in {1..120}; do
    if curl -sf "http://127.0.0.1:8080/health" >/dev/null; then
      break
    fi
    sleep 2
  done
  if ! curl -sf "http://127.0.0.1:8080/health" >/dev/null; then
    echo "[compare] ${label}: server did not become healthy"
    docker logs --tail 120 deeply-tuned-server || true
    exit 1
  fi

  ./reasoning_benchmark_mcq.sh "${label}" "${OUT_DIR}"
}

run_model "q6_k_16k_none0" "/storage/models/Qwen3-32B-GGUF" "Qwen3-32B-Q6_K.gguf"
run_model "q8_0_16k_none0" "/storage/models/Qwen3-32B-Q8_0-GGUF" "Qwen3-32B-Q8_0.gguf"
