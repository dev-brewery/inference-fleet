#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

REQ="${1:-./examples/incident_request.json}"
SERVER="${ROUTER_SERVER_URL:-http://127.0.0.1:8080}"

shift || true
python3 ./router.py --request-file "${REQ}" --server "${SERVER}" "$@"
