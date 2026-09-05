#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
    cp .env.example .env
fi

set -a
source .env
set +a

echo "[1/3] Building compile image (llama.cpp + CUDA sm_61)..."
docker build -f Dockerfile.build -t deeply-tuned-build:latest .

echo "[2/3] Exporting binaries into ./build-staging ..."
mkdir -p build-staging
docker create --name deeply-tuned-build-export deeply-tuned-build:latest >/dev/null
docker cp deeply-tuned-build-export:/out/. ./build-staging/
docker rm deeply-tuned-build-export >/dev/null

echo "[3/3] Building runtime image ${IMAGE_NAME}:${IMAGE_TAG} ..."
docker build -f Dockerfile -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo
echo "Build complete: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "Next: docker compose up -d"

