#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

run_case() {
  local label="$1"
  local chat_template="$2"
  local reasoning_format="$3"
  local reasoning_budget="$4"
  local use_no_think_prefix="$5"

  echo
  echo "[matrix] ===== ${label} ====="
  CHAT_TEMPLATE="${chat_template}" \
  REASONING_FORMAT="${reasoning_format}" \
  REASONING_BUDGET="${reasoning_budget}" \
  docker compose up -d --force-recreate deeply-tuned-ai >/dev/null

  for _ in {1..120}; do
    if curl -sf "http://127.0.0.1:8080/health" >/dev/null; then
      break
    fi
    sleep 2
  done

  if ! curl -sf "http://127.0.0.1:8080/health" >/dev/null; then
    echo "[matrix] ${label}: server did not become healthy"
    docker logs --tail 120 deeply-tuned-server || true
    return 1
  fi

  USE_NO_THINK_PREFIX="${use_no_think_prefix}" ./reasoning_benchmark.sh "${label}" ./bench-results
}

run_case "q6_auto_model_template" "" "auto" "-1" "0"
run_case "q6_no_think_model_template" "" "none" "0" "0"
run_case "q6_no_think_chatml" "chatml" "none" "0" "0"
run_case "q6_auto_chatml" "chatml" "auto" "-1" "0"
