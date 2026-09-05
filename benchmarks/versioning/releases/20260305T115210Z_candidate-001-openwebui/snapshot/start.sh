#!/usr/bin/env bash
set -euo pipefail

MODEL_ROOT="${MODEL_ROOT:-/models}"
MODEL_FILE="${MODEL_FILE:-Qwen3-32B-Q6_K.gguf}"
MODEL_PATH="${MODEL_ROOT}/${MODEL_FILE}"

SERVER_PORT="${SERVER_PORT:-8080}"
CTX_SIZE="${CTX_SIZE:-32768}"
THREADS="${THREADS:-16}"
PARALLEL="${PARALLEL:-1}"
BATCH_SIZE="${BATCH_SIZE:-1024}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"
SPLIT_MODE="${SPLIT_MODE:-row}"
TENSOR_SPLIT="${TENSOR_SPLIT:-24,24}"
FLASH_ATTN="${FLASH_ATTN:-off}"
CACHE_TYPE_K="${CACHE_TYPE_K:-f16}"
CACHE_TYPE_V="${CACHE_TYPE_V:-f16}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"
REASONING_FORMAT="${REASONING_FORMAT:-auto}"
REASONING_BUDGET="${REASONING_BUDGET:--1}"
PROMPT_CACHE_RAM="${PROMPT_CACHE_RAM:-0}"
SEED="${SEED:-42}"
ROUTER_GATEWAY_MODE="${ROUTER_GATEWAY_MODE:-on}"
BACKEND_PORT="${BACKEND_PORT:-8081}"
GATEWAY_MAX_RETRIES="${GATEWAY_MAX_RETRIES:-2}"
GATEWAY_FAIL_ON_VERIFY="${GATEWAY_FAIL_ON_VERIFY:-off}"

echo "[startup] =========================================================="
echo "[startup] Deeply Tuned Dense Inference"
echo "[startup] =========================================================="
echo "[startup] model path: ${MODEL_PATH}"
echo "[startup] ctx: ${CTX_SIZE} | threads: ${THREADS} | parallel: ${PARALLEL}"
echo "[startup] batch: ${BATCH_SIZE} | ubatch: ${UBATCH_SIZE}"
echo "[startup] ngl: ${N_GPU_LAYERS} | split: ${SPLIT_MODE} | ts: ${TENSOR_SPLIT}"
echo "[startup] flash-attn: ${FLASH_ATTN} | ctk: ${CACHE_TYPE_K} | ctv: ${CACHE_TYPE_V}"
echo "[startup] chat-template: ${CHAT_TEMPLATE:-<model-metadata>} | reasoning-format: ${REASONING_FORMAT} | reasoning-budget: ${REASONING_BUDGET}"
echo "[startup] prompt-cache-ram: ${PROMPT_CACHE_RAM} | seed: ${SEED}"
echo "[startup] gateway-mode: ${ROUTER_GATEWAY_MODE} | backend-port: ${BACKEND_PORT} | gateway-retries: ${GATEWAY_MAX_RETRIES} | gateway-fail-on-verify: ${GATEWAY_FAIL_ON_VERIFY}"

export GGML_CUDA_FORCE_MMQ=1
echo "[startup] GGML_CUDA_FORCE_MMQ=1"

if command -v nvidia-smi >/dev/null 2>&1; then
    echo "[startup] GPUs:"
    nvidia-smi --query-gpu=index,name,memory.total,memory.free,compute_cap --format=csv,noheader
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "[startup] ERROR: model not found: ${MODEL_PATH}"
    echo "[startup] Mount the model directory or change MODEL_ROOT/MODEL_FILE in .env"
    exit 1
fi

ARGS=(
  -m "${MODEL_PATH}"
  --host 0.0.0.0
  --port "${SERVER_PORT}"
  -c "${CTX_SIZE}"
  -t "${THREADS}"
  -np "${PARALLEL}"
  --batch-size "${BATCH_SIZE}"
  --ubatch-size "${UBATCH_SIZE}"
  -ngl "${N_GPU_LAYERS}"
  -sm "${SPLIT_MODE}"
  -ts "${TENSOR_SPLIT}"
  --flash-attn "${FLASH_ATTN}"
  -ctk "${CACHE_TYPE_K}"
  -ctv "${CACHE_TYPE_V}"
  --reasoning-format "${REASONING_FORMAT}"
  --reasoning-budget "${REASONING_BUDGET}"
  --cache-ram "${PROMPT_CACHE_RAM}"
  --seed "${SEED}"
  --mlock
  --metrics
)

if [[ -n "${CHAT_TEMPLATE}" ]]; then
  ARGS+=(--chat-template "${CHAT_TEMPLATE}")
fi

if [[ "${ROUTER_GATEWAY_MODE}" == "on" ]]; then
  BACKEND_ARGS=("${ARGS[@]}")
  for i in "${!BACKEND_ARGS[@]}"; do
    if [[ "${BACKEND_ARGS[$i]}" == "--host" ]]; then
      BACKEND_ARGS[$((i+1))]="127.0.0.1"
    fi
    if [[ "${BACKEND_ARGS[$i]}" == "--port" ]]; then
      BACKEND_ARGS[$((i+1))]="${BACKEND_PORT}"
    fi
  done

  /app/llama-server "${BACKEND_ARGS[@]}" &
  BACKEND_PID=$!
  echo "[startup] backend llama-server pid=${BACKEND_PID} on 127.0.0.1:${BACKEND_PORT}"

  cleanup() {
    if kill -0 "${BACKEND_PID}" >/dev/null 2>&1; then
      kill "${BACKEND_PID}" >/dev/null 2>&1 || true
      wait "${BACKEND_PID}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT INT TERM

  for _ in {1..120}; do
    if curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" >/dev/null; then
      break
    fi
    sleep 1
  done

  if ! curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" >/dev/null; then
    echo "[startup] ERROR: backend did not become healthy on ${BACKEND_PORT}"
    exit 1
  fi

  echo "[startup] launching router gateway on 0.0.0.0:${SERVER_PORT}"
  GW_ARGS=(
    --host 0.0.0.0
    --port "${SERVER_PORT}"
    --llm-server "http://127.0.0.1:${BACKEND_PORT}"
    --max-retries "${GATEWAY_MAX_RETRIES}"
  )
  if [[ "${GATEWAY_FAIL_ON_VERIFY}" == "on" ]]; then
    GW_ARGS+=(--fail-on-verify)
  fi
  exec python3 /router/gateway.py \
    "${GW_ARGS[@]}"
else
  exec /app/llama-server "${ARGS[@]}"
fi
