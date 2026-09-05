#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Load persisted OpenWebUI credentials/config if present.
# Search local test dir first, then parent deeply-tuned dir.
for env_file in ./.owui.env ../.owui.env; do
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
    break
  fi
done

python3 ./test_openwebui.py
