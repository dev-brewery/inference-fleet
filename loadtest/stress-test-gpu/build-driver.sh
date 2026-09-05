#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
docker build -t stress-driver:latest -f driver.Dockerfile .
echo "Built stress-driver:latest"
docker images stress-driver:latest
