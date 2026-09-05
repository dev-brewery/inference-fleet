FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y \
    curl \
    python3 \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY build-staging/llama-server /app/llama-server
COPY build-staging/llama-cli /app/llama-cli
COPY build-staging/llama-bench /app/llama-bench
COPY build-staging/libllama.so /app/libllama.so
COPY build-staging/libggml.so /app/libggml.so
COPY build-staging/libggml-base.so /app/libggml-base.so
COPY build-staging/libggml-cpu.so /app/libggml-cpu.so
COPY build-staging/libggml-cuda.so /app/libggml-cuda.so
COPY build-staging/libmtmd.so /app/libmtmd.so
COPY router /router

ENV LD_LIBRARY_PATH=/app:$LD_LIBRARY_PATH

RUN ln -sf /app/libllama.so /app/libllama.so.0 && \
    ln -sf /app/libggml.so /app/libggml.so.0 && \
    ln -sf /app/libggml-base.so /app/libggml-base.so.0 && \
    ln -sf /app/libggml-cpu.so /app/libggml-cpu.so.0 && \
    ln -sf /app/libggml-cuda.so /app/libggml-cuda.so.0 && \
    ln -sf /app/libmtmd.so /app/libmtmd.so.0

ENTRYPOINT ["/app/llama-server"]
