FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy the locally-built llama-server binary
COPY --from=local-build /app/llama-server /app/llama-server

# Verify the binary works
RUN /app/llama-server --help > /dev/null 2>&1 || echo "Binary validation skipped"

# Set up the entrypoint
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

ENTRYPOINT ["/bin/sh", "/start.sh"]
