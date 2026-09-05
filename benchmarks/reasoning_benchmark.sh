#!/usr/bin/env bash
set -euo pipefail

PORT="${SERVER_PORT:-8080}"
MODEL_LABEL="${1:-unknown}"
OUT_DIR="${2:-./bench-results}"
USE_NO_THINK_PREFIX="${USE_NO_THINK_PREFIX:-1}"
mkdir -p "${OUT_DIR}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${OUT_DIR}/reasoning_${MODEL_LABEL}_${TS}.tsv"

echo -e "id\texpected\tactual\tpass\tgen_tps\tprompt_tps" > "${OUT_FILE}"

# id<TAB>expected<TAB>prompt
CASES=(
  $'arith_1\t182\tCompute: 17*23 - 19*11. Return exactly: FINAL: <number>.'
  $'sequence_1\t42\tFind the next number: 2, 6, 12, 20, 30, ?. Return exactly: FINAL: <number>.'
  $'logic_1\tNO\tAll fribs are lums. No lums are norks. Can any fribs be norks? Return exactly: FINAL: YES or FINAL: NO.'
  $'count_1\t47\tHow many integers from 1 to 100 are divisible by 3 or 5? Return exactly: FINAL: <number>.'
  $'letters_1\tBOKEPR\tRemove repeated letters from BOOKKEEPER while keeping first occurrence order. Return exactly: FINAL: <string>.'
  $'labels_1\tBOTH\tThree boxes are labeled APPLES, ORANGES, BOTH, and all labels are wrong. You may draw one fruit from one box to relabel all correctly. Which box must you draw from? Return exactly: FINAL: APPLES or FINAL: ORANGES or FINAL: BOTH.'
  $'parity_1\t15\tThere are 7 odd numbers and 8 even numbers. How many odd+even pairs make an odd sum? Return exactly: FINAL: <number>.'
  $'clock_1\t135\tAt 3:30, what is the smaller angle between hour and minute hands in degrees? Return exactly: FINAL: <number>.'
  $'rates_1\t24\tA can do a job in 6 hours, B in 8 hours. Working together, how many minutes to finish one job? Return exactly: FINAL: <number>.'
  $'syllogism_1\tA_KNIGHT_B_LIAR\tA says: \"B is a liar.\" B says: \"We are the same type.\" Determine types. Return exactly: FINAL: A_KNIGHT_B_LIAR or FINAL: A_LIAR_B_KNIGHT.'
)

total=0
passed=0
sum_gen_tps=0
sum_prompt_tps=0

for case in "${CASES[@]}"; do
  IFS=$'\t' read -r id expected prompt <<< "${case}"
  total=$((total + 1))

  if [[ "${USE_NO_THINK_PREFIX}" == "1" ]]; then
    prompt_with_mode="/no_think
You are a deterministic reasoning engine.
Output exactly one line in this format and nothing else:
FINAL: <answer>

${prompt}"
  else
    prompt_with_mode="You are a deterministic reasoning engine.
Output exactly one line in this format and nothing else:
FINAL: <answer>

${prompt}"
  fi

  payload="$(python3 -c '
import json, sys
p = sys.argv[1]
print(json.dumps({
  "model": "local",
  "messages": [{"role": "user", "content": p}],
  "max_tokens": 48,
  "temperature": 0.0,
  "top_p": 1.0,
  "top_k": 1,
  "seed": 42
}))
' "${prompt_with_mode}")"

  resp="$(curl -sS "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "${payload}")"

  content="$(python3 -c '
import json, sys
try:
  data = json.loads(sys.stdin.read())
  msg = data.get("choices", [{}])[0].get("message", {})
  text = msg.get("content") or msg.get("reasoning_content") or ""
  print(text)
except Exception:
  print("")
' <<< "${resp}")"
  gen_tps="$(python3 -c '
import json, sys
try:
  data = json.loads(sys.stdin.read())
  print(data.get("timings", {}).get("predicted_per_second", 0))
except Exception:
  print(0)
' <<< "${resp}")"
  prompt_tps="$(python3 -c '
import json, sys
try:
  data = json.loads(sys.stdin.read())
  print(data.get("timings", {}).get("prompt_per_second", 0))
except Exception:
  print(0)
' <<< "${resp}")"

  actual="$(printf '%s' "${content}" \
    | tr -d '\r' \
    | sed -n 's/.*FINAL:[[:space:]]*//Ip' \
    | head -n1 \
    | tr -d ' ' \
    | tr '[:lower:]' '[:upper:]')"

  expected_norm="$(printf '%s' "${expected}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  pass=0
  content_upper="$(printf '%s' "${content}" | tr '[:lower:]' '[:upper:]')"

  if [[ -n "${actual}" && "${actual}" == "${expected_norm}" ]]; then
    pass=1
    passed=$((passed + 1))
  elif [[ -z "${actual}" ]]; then
    candidate="$(printf '%s' "${content_upper}" | rg -o '[A-Z0-9_]+[*]*' | tail -n1 || true)"
    if [[ -n "${candidate}" ]]; then
      actual="${candidate}"
    fi
  fi

  if [[ "${pass}" -eq 0 && -n "${actual}" ]]; then
    cleaned_actual="$(printf '%s' "${actual}" | tr -d '*.,;:!?')"
    if [[ "${cleaned_actual}" == "${expected_norm}" ]]; then
      actual="${cleaned_actual}"
      pass=1
      passed=$((passed + 1))
    fi
  fi

  sum_gen_tps="$(awk -v a="${sum_gen_tps}" -v b="${gen_tps}" 'BEGIN { printf "%.6f", a+b }')"
  sum_prompt_tps="$(awk -v a="${sum_prompt_tps}" -v b="${prompt_tps}" 'BEGIN { printf "%.6f", a+b }')"

  echo -e "${id}\t${expected}\t${actual:-<none>}\t${pass}\t${gen_tps}\t${prompt_tps}" >> "${OUT_FILE}"
  echo "[${MODEL_LABEL}] ${id}: pass=${pass} expected=${expected_norm} actual=${actual:-<none>} gen_tps=${gen_tps}"
done

acc="$(awk -v p="${passed}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.2f", (100*p)/t }')"
avg_gen_tps="$(awk -v s="${sum_gen_tps}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.3f", s/t }')"
avg_prompt_tps="$(awk -v s="${sum_prompt_tps}" -v t="${total}" 'BEGIN { if (t==0) print "0.00"; else printf "%.3f", s/t }')"

echo
echo "model=${MODEL_LABEL} total=${total} passed=${passed} accuracy=${acc}% avg_gen_tps=${avg_gen_tps} avg_prompt_tps=${avg_prompt_tps}"
echo "results=${OUT_FILE}"
