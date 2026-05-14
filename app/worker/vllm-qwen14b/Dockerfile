# vllm-qwen14b — large-model worker image
#
# Independent build, no shared base. The pip install of vLLM is the
# heavy step; Docker's layer cache makes back-to-back builds of all
# five worker images cheap on the same host since the install layers
# are byte-identical.
FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
        python3.10 python3-pip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip

# vLLM 0.11 needs transformers 4.57.x (see notes in laptop branch:
# transformers 5.x breaks Qwen2Tokenizer.all_special_tokens_extended).
RUN pip install vllm==0.11.0 transformers==4.57.6 \
        --extra-index-url https://download.pytorch.org/whl/cu122

# Business code lives here. The K8s Deployment doesn't override CMD so
# vLLM's openai.api_server runs directly; if you add pre/post processing
# in handlers/, wrap that into a small launcher and update the Deployment
# command:/args:.
COPY handlers/ /app/handlers/

ENV PYTHONUNBUFFERED=1
EXPOSE 8002
