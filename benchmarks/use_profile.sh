#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PROFILE="${1:-production}"
SRC="./profiles/${PROFILE}.env"

if [[ ! -f "${SRC}" ]]; then
  echo "profile not found: ${SRC}"
  exit 1
fi

cp "${SRC}" ./.env
echo "applied profile: ${PROFILE}"
echo "restart with: docker compose up -d"
