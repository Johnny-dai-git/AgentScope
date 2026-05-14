# vllm-qwen7b — medium-model worker image
FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
        python3.10 python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip

RUN pip install vllm==0.11.0 transformers==4.57.6 \
        --extra-index-url https://download.pytorch.org/whl/cu122

COPY handlers/ /app/handlers/

ENV PYTHONUNBUFFERED=1
EXPOSE 8002
