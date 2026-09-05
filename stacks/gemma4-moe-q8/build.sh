#!/bin/bash
##############################################################################
# Build script for Gemma 4 26B-A4B Docker image
#
# IMPORTANT: This stack uses its OWN llama.cpp backend (upstream ggml-org),
# NOT the shared ik_llama.cpp-gpu used by all other GPU stacks.
#
# Why a separate backend?
#   - ik_llama.cpp dropped Pascal (P40) GPU support — README says "Turing or
#     newer" and won't accept issues for older GPUs. Optimizations increasingly
#     target Turing+.
#   - Upstream ggml-org/llama.cpp still treats Pascal (CC 6.1) as the official
#     minimum CUDA target, with active maintenance and bug fixes.
#   - Gemma 4 model support landed in upstream with 7+ PRs (tokenizer, KV
#     cache, softcapping, template parsing, etc.).
#
# This means: rebuilding ik_llama.cpp-gpu for other stacks will NOT affect
# this stack, and vice versa. They are fully independent.
##############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_DIR="$SCRIPT_DIR/llama.cpp"
IMAGE_NAME="gemma4-server-local"
IMAGE_TAG="latest"

echo "=========================================="
echo "Building Gemma 4 26B-A4B Docker Image"
echo "=========================================="
echo ""
echo "Backend: upstream ggml-org/llama.cpp (NOT ik_llama.cpp)"
echo "Target:  CUDA arch 61 (Pascal / Tesla P40)"
echo ""

# Step 1: Build llama-server from source
if [ ! -d "$LLAMA_CPP_DIR" ]; then
    echo "ERROR: llama.cpp not found at: $LLAMA_CPP_DIR"
    echo "Clone it first:"
    echo "  cd $SCRIPT_DIR"
    echo "  git clone https://github.com/ggml-org/llama.cpp.git"
    exit 1
fi

echo "Building llama-server from source..."
cd "$LLAMA_CPP_DIR"

mkdir -p build
cd build

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES=61 \
    -DGGML_CUDA_FA_ALL_QUANTS=OFF

cmake --build . --target llama-server -j$(nproc)

if [ ! -f bin/llama-server ]; then
    echo "ERROR: Build failed — bin/llama-server not found"
    exit 1
fi

echo "llama-server built successfully."
echo ""

# Step 2: Build Docker image
BUILD_CONTEXT=$(mktemp -d)
trap "rm -rf $BUILD_CONTEXT" EXIT

echo "Preparing Docker build context in: $BUILD_CONTEXT"

mkdir -p "$BUILD_CONTEXT/app"
cp "$LLAMA_CPP_DIR/build/bin/llama-server" "$BUILD_CONTEXT/app/llama-server"
cp "$LLAMA_CPP_DIR/build/bin"/lib*.so* "$BUILD_CONTEXT/app/" 2>/dev/null || true

cp "$SCRIPT_DIR/start.sh" "$BUILD_CONTEXT/start.sh"

cat > "$BUILD_CONTEXT/Dockerfile" <<'EOF'
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y \
    curl \
    libgomp1 \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY app/ /app/

ENV LD_LIBRARY_PATH=/app:$LD_LIBRARY_PATH

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

ENTRYPOINT ["/bin/sh", "/start.sh"]
EOF

echo "Building Docker image: $IMAGE_NAME:$IMAGE_TAG"
docker build -t "$IMAGE_NAME:$IMAGE_TAG" "$BUILD_CONTEXT"

echo ""
echo "=========================================="
echo "Build complete!"
echo "Image: $IMAGE_NAME:$IMAGE_TAG"
echo ""
echo "Backend: upstream ggml-org/llama.cpp"
echo "  (independent from ik_llama.cpp-gpu used by other stacks)"
echo ""
echo "To run:"
echo "  docker compose up -d"
echo "=========================================="
