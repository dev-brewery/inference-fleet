#!/bin/bash
##############################################################################
# Build script for Qwen3.6-27B Dense Docker image
#
# Uses upstream ggml-org/llama.cpp compiled for Pascal P40 (CC 6.1).
# Fully independent — does NOT share images or backends with any other stack.
##############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_DIR="$SCRIPT_DIR/llama.cpp"
IMAGE_NAME="qwen36-dense-server-local"
IMAGE_TAG="latest"

echo "=========================================="
echo "Building Qwen3.6-27B Dense Docker Image"
echo "=========================================="
echo ""
echo "Backend: upstream ggml-org/llama.cpp"
echo "Target:  CUDA arch 61 (Pascal / Tesla P40)"
echo ""

if [ ! -d "$LLAMA_CPP_DIR" ]; then
    echo "ERROR: llama.cpp not found at: $LLAMA_CPP_DIR"
    echo "Clone it first:"
    echo "  cd $SCRIPT_DIR"
    echo "  git clone https://github.com/ggml-org/llama.cpp.git"
    exit 1
fi

if [ ! -f "$LLAMA_CPP_DIR/build/bin/llama-server" ]; then
    echo "ERROR: llama-server not compiled yet."
    echo "Compile first:"
    echo "  cd $LLAMA_CPP_DIR && mkdir -p build && cd build"
    echo "  cmake .. -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=61 -DCMAKE_BUILD_TYPE=Release"
    echo "  cmake --build . --target llama-server -j\$(nproc)"
    exit 1
fi

echo "Using pre-compiled llama-server from: $LLAMA_CPP_DIR/build/bin/"

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
echo ""
echo "To run:"
echo "  docker compose up -d"
echo "=========================================="
