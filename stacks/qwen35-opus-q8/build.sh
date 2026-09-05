#!/bin/bash
##############################################################################
# Build script for custom Qwen3-Coder-Next Docker image
##############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BUILD_DIR="~/llm-hosts/ik_llama.cpp-gpu/build"
IMAGE_NAME="qwen3-server-local"
IMAGE_TAG="latest"

echo "=========================================="
echo "Building Qwen3-Coder-Next Docker Image"
echo "=========================================="
echo ""

# Verify local build exists
if [ ! -f "$LOCAL_BUILD_DIR/bin/llama-server" ]; then
    echo "ERROR: llama-server not found at: $LOCAL_BUILD_DIR/bin/llama-server"
    echo "Please build llama.cpp first:"
    echo "  cd $LOCAL_BUILD_DIR"
    echo "  cmake .. && make llama-server"
    exit 1
fi

echo "Local llama-server found: $LOCAL_BUILD_DIR/bin/llama-server"
echo "Image name: $IMAGE_NAME:$IMAGE_TAG"
echo ""

# Create a temporary directory for the build context
BUILD_CONTEXT=$(mktemp -d)
trap "rm -rf $BUILD_CONTEXT" EXIT

echo "Preparing build context in: $BUILD_CONTEXT"

# Copy the binary and all required libraries to build context
mkdir -p "$BUILD_CONTEXT/app"
cp "$LOCAL_BUILD_DIR/bin/llama-server" "$BUILD_CONTEXT/app/llama-server"
cp "$LOCAL_BUILD_DIR/bin"/lib*.so* "$BUILD_CONTEXT/app/" 2>/dev/null || true

# Copy start.sh
cp "$SCRIPT_DIR/start.sh" "$BUILD_CONTEXT/start.sh"

# Copy Dockerfile (modify it for this context)
cat > "$BUILD_CONTEXT/Dockerfile" <<'EOF'
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    libgomp1 \
    libssl3 \
    libcrypto++ \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy the locally-built binaries and libraries
COPY app/ /app/

# Set library path so binary can find local libraries
ENV LD_LIBRARY_PATH=/app:$LD_LIBRARY_PATH

# Set up the entrypoint
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

ENTRYPOINT ["/bin/sh", "/start.sh"]
EOF

echo "Building Docker image..."
docker build -t "$IMAGE_NAME:$IMAGE_TAG" "$BUILD_CONTEXT"

echo ""
echo "=========================================="
echo "Build complete!"
echo "Image: $IMAGE_NAME:$IMAGE_TAG"
echo ""
echo "To run:"
echo "  docker compose up -d"
echo "=========================================="
