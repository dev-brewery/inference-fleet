#!/usr/bin/env bash
set -euo pipefail

URL="${1:-http://127.0.0.1:8080/v1/chat/completions}"
RUNS="${2:-20}"
TIMEOUT_S="${3:-180}"

pass=0
fail=0

echo "[monitor] url=${URL} runs=${RUNS} timeout=${TIMEOUT_S}s"

for i in $(seq 1 "${RUNS}"); do
  payload='{"model":"local","stream":true,"max_tokens":256,"messages":[{"role":"user","content":"Write a 12-point reliability checklist for operating an LLM service with streaming responses."}]}'
  out="$(curl -N -sS --max-time "${TIMEOUT_S}" "${URL}" -H 'Content-Type: application/json' -d "${payload}" || true)"

  has_done=0
  if printf '%s' "${out}" | rg -q 'data: \[DONE\]'; then
    has_done=1
  fi
  has_chunk=0
  if printf '%s' "${out}" | rg -q '"chat.completion.chunk"'; then
    has_chunk=1
  fi

  if [[ "${has_done}" -eq 1 && "${has_chunk}" -eq 1 ]]; then
    pass=$((pass + 1))
    echo "[monitor] run=${i} PASS"
  else
    fail=$((fail + 1))
    echo "[monitor] run=${i} FAIL (has_chunk=${has_chunk} has_done=${has_done})"
  fi
done

rate="$(awk -v p="${pass}" -v t="${RUNS}" 'BEGIN { if (t==0) print "0.00"; else printf "%.2f", (100*p)/t }')"
echo
echo "[monitor] summary pass=${pass} fail=${fail} success_rate=${rate}%"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
