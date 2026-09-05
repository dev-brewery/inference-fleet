#!/usr/bin/env bash
set -euo pipefail

PORT="${SERVER_PORT:-8080}"
MODEL_LABEL="${1:-unknown}"
OUT_DIR="${2:-./bench-results}"
CASES_FILE="${CASES_FILE:-./benchmark_cases_mcq.tsv}"
mkdir -p "${OUT_DIR}"

if [[ ! -f "${CASES_FILE}" ]]; then
  echo "cases file not found: ${CASES_FILE}"
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${OUT_DIR}/reasoning_mcq_${MODEL_LABEL}_${TS}.tsv"
echo -e "id\texpected\tpass1\tans1\tuncertain1\tpass2_uncertain\tans2_uncertain\tpass2_all\tans2_all\tgen_tps_1\tgen_tps_2_uncertain\tgen_tps_2_all" > "${OUT_FILE}"

if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
  echo "server is not healthy on :${PORT}"
  exit 1
fi

call_model() {
  local prompt="$1"
  local max_tokens="${2:-12}"
  local payload
  payload="$(python3 -c '
import json, sys
p = sys.argv[1]
t = int(sys.argv[2])
print(json.dumps({
  "model": "local",
  "messages": [{"role": "user", "content": p}],
  "max_tokens": t,
  "temperature": 0.0,
  "top_p": 1.0,
  "top_k": 1,
  "seed": 42
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

extract_letter() {
  local text="$1"
  local letter
  letter="$(printf '%s' "${text}" \
    | tr -d '\r' \
    | tr '[:lower:]' '[:upper:]' \
    | rg -o '\b[ABCD]\b' \
    | tail -n1 || true)"
  printf '%s' "${letter}"
}

is_uncertain() {
  local text="$1"
  local ans="$2"
  local upper
  upper="$(printf '%s' "${text}" | tr '[:lower:]' '[:upper:]')"

  if [[ ! "${ans}" =~ ^[ABCD]$ ]]; then
    return 0
  fi
  if printf '%s' "${upper}" | rg -q '\b(NOT SURE|UNSURE|MAYBE|DEPENDS|CANNOT DETERMINE|CAN.?T DETERMINE)\b'; then
    return 0
  fi
  return 1
}

total=0
pass1=0
pass2_uncertain=0
pass2_all=0
sum_tps_1=0
sum_tps_2u=0
sum_tps_2a=0

while IFS=$'\t' read -r id expected question options; do
  if [[ "${id}" == "id" ]]; then
    continue
  fi
  total=$((total + 1))

  prompt1="You are solving a multiple-choice reasoning problem.
Return exactly one character: A, B, C, or D.
Do not output words.

Question:
${question}
${options}
Answer:"

  resp1="$(call_model "${prompt1}" 8)"
  text1="$(printf '%s' "${resp1}" | extract_text)"
  tps1="$(printf '%s' "${resp1}" | extract_tps)"
  ans1="$(extract_letter "${text1}")"
  [[ -z "${ans1}" ]] && ans1="<none>"

  row_pass1=0
  if [[ "${ans1}" == "${expected}" ]]; then
    row_pass1=1
    pass1=$((pass1 + 1))
  fi

  uncertain1=0
  if is_uncertain "${text1}" "${ans1}"; then
    uncertain1=1
  fi

  row_pass2u="${row_pass1}"
  ans2u="${ans1}"
  tps2u="0"
  if [[ "${uncertain1}" -eq 1 ]]; then
    prompt2u="Re-evaluate carefully.
Return exactly one character: A, B, C, or D.
Question:
${question}
${options}
Previous answer: ${ans1}
Corrected answer:"
    resp2u="$(call_model "${prompt2u}" 8)"
    text2u="$(printf '%s' "${resp2u}" | extract_text)"
    ans2u="$(extract_letter "${text2u}")"
    [[ -z "${ans2u}" ]] && ans2u="<none>"
    tps2u="$(printf '%s' "${resp2u}" | extract_tps)"
    if [[ "${row_pass2u}" -eq 0 && "${ans2u}" == "${expected}" ]]; then
      row_pass2u=1
    fi
  fi
  if [[ "${row_pass2u}" -eq 1 ]]; then
    pass2_uncertain=$((pass2_uncertain + 1))
  fi

  # Upper-bound retry metric: second pass on all misses.
  row_pass2a="${row_pass1}"
  ans2a="${ans1}"
  tps2a="0"
  if [[ "${row_pass1}" -eq 0 ]]; then
    prompt2a="You answered this incorrectly before. Solve again from scratch.
Return exactly one character: A, B, C, or D.
Question:
${question}
${options}
Answer:"
    resp2a="$(call_model "${prompt2a}" 8)"
    text2a="$(printf '%s' "${resp2a}" | extract_text)"
    ans2a="$(extract_letter "${text2a}")"
    [[ -z "${ans2a}" ]] && ans2a="<none>"
    tps2a="$(printf '%s' "${resp2a}" | extract_tps)"
    if [[ "${ans2a}" == "${expected}" ]]; then
      row_pass2a=1
    fi
  fi
  if [[ "${row_pass2a}" -eq 1 ]]; then
    pass2_all=$((pass2_all + 1))
  fi

  sum_tps_1="$(awk -v a="${sum_tps_1}" -v b="${tps1}" 'BEGIN { printf "%.6f", a+b }')"
  sum_tps_2u="$(awk -v a="${sum_tps_2u}" -v b="${tps2u}" 'BEGIN { printf "%.6f", a+b }')"
  sum_tps_2a="$(awk -v a="${sum_tps_2a}" -v b="${tps2a}" 'BEGIN { printf "%.6f", a+b }')"

  echo -e "${id}\t${expected}\t${row_pass1}\t${ans1}\t${uncertain1}\t${row_pass2u}\t${ans2u}\t${row_pass2a}\t${ans2a}\t${tps1}\t${tps2u}\t${tps2a}" >> "${OUT_FILE}"
  echo "[${MODEL_LABEL}] ${id}: exp=${expected} ans1=${ans1} p1=${row_pass1} uncertain=${uncertain1} ans2u=${ans2u} p2u=${row_pass2u} ans2a=${ans2a} p2a=${row_pass2a}"
done < "${CASES_FILE}"

acc1="$(awk -v p="${pass1}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.2f", (100*p)/t }')"
acc2u="$(awk -v p="${pass2_uncertain}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.2f", (100*p)/t }')"
acc2a="$(awk -v p="${pass2_all}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.2f", (100*p)/t }')"
avg_tps1="$(awk -v s="${sum_tps_1}" -v t="${total}" 'BEGIN { if (t==0) print "0.000"; else printf "%.3f", s/t }')"

echo
echo "model=${MODEL_LABEL} total=${total} pass1=${pass1} acc1=${acc1}% pass2_uncertain=${pass2_uncertain} acc2_uncertain=${acc2u}% pass2_all=${pass2_all} acc2_all=${acc2a}% avg_gen_tps_pass1=${avg_tps1}"
echo "results=${OUT_FILE}"
