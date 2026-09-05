#!/usr/bin/env bash
set -euo pipefail

PORT="${SERVER_PORT:-8080}"
MODEL_LABEL="${1:-unknown}"
OUT_DIR="${2:-./bench-results}"
CASES_FILE="${CASES_FILE:-./benchmark_cases_real.tsv}"
mkdir -p "${OUT_DIR}"

if [[ ! -f "${CASES_FILE}" ]]; then
  echo "cases file not found: ${CASES_FILE}"
  exit 1
fi

if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
  echo "server is not healthy on :${PORT}"
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${OUT_DIR}/reasoning_real_${MODEL_LABEL}_${TS}.tsv"
echo -e "id\ttype\tpass\tmatched_required\ttotal_required\tforbidden_hit\tgen_tps\tresponse" > "${OUT_FILE}"

call_model() {
  local prompt="$1"
  local max_tokens="${2:-220}"
  local payload
  payload="$(python3 -c '
import json, sys
p = sys.argv[1]
t = int(sys.argv[2])
print(json.dumps({
  "model": "local",
  "messages": [{"role": "user", "content": p}],
  "max_tokens": t,
  "temperature": 0.0
}))
' "${prompt}" "${max_tokens}")"

  curl -sS "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "${payload}"
}

extract_text() {
  python3 -c '
import json, sys
try:
  data = json.loads(sys.stdin.read())
  msg = data.get("choices", [{}])[0].get("message", {})
  print((msg.get("content") or msg.get("reasoning_content") or "").strip())
except Exception:
  print("")
'
}

extract_tps() {
  python3 -c '
import json, sys
try:
  data = json.loads(sys.stdin.read())
  print(data.get("timings", {}).get("predicted_per_second", 0))
except Exception:
  print(0)
'
}

escape_tsv() {
  printf '%s' "$1" | tr '\t' ' ' | tr '\n' ' ' | tr -s ' '
}

total=0
passed=0
sum_gen_tps=0

while IFS=$'\t' read -r id expected_type user_request required_regex forbidden_regex; do
  if [[ "${id}" == "id" ]]; then
    continue
  fi

  total=$((total + 1))

  prompt="You are a senior engineer assisting with a real user request.
Give a direct, correct answer.
For code/commands, provide runnable output.
Do not include hidden reasoning text.

Request:
${user_request}"

  resp="$(call_model "${prompt}" 260)"
  text="$(printf '%s' "${resp}" | extract_text)"
  gen_tps="$(printf '%s' "${resp}" | extract_tps)"
  text_upper="$(printf '%s' "${text}" | tr '[:lower:]' '[:upper:]')"

  matched=0
  total_req=0
  IFS='|' read -r -a reqs <<< "${required_regex}"
  for r in "${reqs[@]}"; do
    if [[ -z "${r}" ]]; then
      continue
    fi
    total_req=$((total_req + 1))
    if printf '%s' "${text}" | rg -qi "${r}"; then
      matched=$((matched + 1))
    fi
  done

  forbidden_hit=0
  if [[ -n "${forbidden_regex}" ]] && printf '%s' "${text}" | rg -qi "${forbidden_regex}"; then
    forbidden_hit=1
  fi

  pass=0
  if [[ "${total_req}" -gt 0 && "${matched}" -eq "${total_req}" && "${forbidden_hit}" -eq 0 ]]; then
    pass=1
    passed=$((passed + 1))
  fi

  sum_gen_tps="$(awk -v a="${sum_gen_tps}" -v b="${gen_tps}" 'BEGIN { printf "%.6f", a+b }')"

  echo -e "${id}\t${expected_type}\t${pass}\t${matched}\t${total_req}\t${forbidden_hit}\t${gen_tps}\t$(escape_tsv "${text}")" >> "${OUT_FILE}"
  echo "[${MODEL_LABEL}] ${id}: pass=${pass} matched=${matched}/${total_req} forbidden=${forbidden_hit} gen_tps=${gen_tps}"
done < "${CASES_FILE}"

acc="$(awk -v p="${passed}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.2f", (100*p)/t }')"
avg_gen_tps="$(awk -v s="${sum_gen_tps}" -v t="${total}" 'BEGIN { if (t==0) print "0.000"; else printf "%.3f", s/t }')"

echo
echo "model=${MODEL_LABEL} total=${total} passed=${passed} accuracy=${acc}% avg_gen_tps=${avg_gen_tps}"
echo "results=${OUT_FILE}"
