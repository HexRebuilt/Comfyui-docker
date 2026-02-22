FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_NO_CACHE_DIR=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

ENV COMFYUI_PATH=/opt/ComfyUI
ENV AUTO_UPDATE=true
ENV UPDATE_SCHEDULE="0 4 * * *"

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3-pip \
    git \
    curl \
    cron \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel \
    && pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

WORKDIR /opt
RUN git clone https://github.com/Comfy-Org/ComfyUI.git ${COMFYUI_PATH}

WORKDIR ${COMFYUI_PATH}
RUN pip install -r requirements.txt

RUN mkdir -p models/checkpoints models/vae models/loras models/embeddings models/controlnet input output custom_nodes

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

RUN echo "${UPDATE_SCHEDULE} cd ${COMFYUI_PATH} && git fetch origin && git pull --ff-only && echo 'ComfyUI updated at \$(date)' >> /var/log/comfyui-update.log 2>&1" | crontab -

EXPOSE 8188

VOLUME ["${COMFYUI_PATH}/models", "${COMFYUI_PATH}/input", "${COMFYUI_PATH}/output", "${COMFYUI_PATH}/custom_nodes"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
