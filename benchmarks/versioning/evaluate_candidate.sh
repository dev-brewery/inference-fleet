#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 ./versioning/evaluate_candidate.py "$@"
