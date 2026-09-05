#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

python3 ./router_regression.py \
  --cases ./benchmark_cases_real.tsv \
  --router ./router/router.py \
  --server "${ROUTER_SERVER_URL:-http://127.0.0.1:8080}" \
  --max-retries "${1:-1}" \
  --out-dir ./bench-results
