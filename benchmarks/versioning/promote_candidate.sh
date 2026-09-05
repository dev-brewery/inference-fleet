#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
python3 ./versioning/promote_candidate.py "$@"
