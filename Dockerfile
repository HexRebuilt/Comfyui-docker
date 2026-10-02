# syntax=docker/dockerfile:1.7
#
# ComfyUI container with GPU acceleration and self-update.
#
# Base image is pinned to CUDA 13 / Ubuntu 24.04 because:
#   - CUDA <= 12.7 cannot target sm_89 (RTX 2000 Ada) natively and cannot
#     target sm_120 (RTX 50-series / Blackwell) at all.
#   - cu121 was capped at torch 2.5.1 (Oct 2024) and is no longer published.
#   - ComfyUI's `comfy-kitchen` dependency requires cuBLASLt 13.x (CUDA 13+).
# See README "GPU support matrix".
FROM nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04

# Explicit because later steps pipe into tee/cut and rely on pipefail to catch
# a failing left-hand command.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG COMFYUI_REF=master
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    COMFYUI_PATH=/opt/ComfyUI \
    VENV_PATH=/opt/venv \
    UPDATE_LOG=/var/log/comfyui-update.log \
    AUTO_UPDATE=true \
    UPDATE_INTERVAL=24h \
    HF_HOME=/home/comfy/.cache/huggingface

# git/curl are needed by the updater and the HF CLI.
#
# The explicit openssl install is not redundant: the base image ships
# 3.0.13-0ubuntu3.9, and Ubuntu has since fixed CVE-2026-45447 (heap
# use-after-free in PKCS7_verify) and CVE-2026-84782 (DTLS info disclosure).
# Pulling it explicitly is what keeps the published image free of them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssl \
        python3 \
        python3-pip \
        python3-venv \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged runtime user. UID/GID are build args so host bind mounts
# (./models, ./output, ...) line up with the invoking user.
#
# The base image already ships a group with GID 1000, so the group is reused
# when the requested GID is taken rather than failing the build. useradd -o
# permits a duplicate UID for the same reason.
ARG COMFYUI_UID=1000
ARG COMFYUI_GID=1000
RUN if getent group "${COMFYUI_GID}" >/dev/null; then \
        group_mod="$(getent group "${COMFYUI_GID}" | cut -d: -f1)"; \
    else \
        groupadd --gid "${COMFYUI_GID}" comfy && group_mod=comfy; \
    fi; \
    id -u comfy >/dev/null 2>&1 || \
        useradd --uid "${COMFYUI_UID}" --gid "${group_mod}" --non-unique \
            --create-home --shell /bin/bash comfy; \
    # Fail loudly rather than silently running as the wrong uid.
    [ "$(id -u comfy)" = "${COMFYUI_UID}" ]

# Python environment in a venv owned by the runtime user, so the entrypoint's
# `pip install` during an auto-update does not need root.
RUN python3 -m venv "${VENV_PATH}" \
    && chown -R "${COMFYUI_UID}:${COMFYUI_GID}" "${VENV_PATH}"

ENV PATH="/opt/venv/bin:${PATH}"
ENV VIRTUAL_ENV=/opt/venv

# Torch first, from the CUDA 13 index, so the matching cu130 wheels are
# selected. torch/torchvision/torchaudio are pinned to one mutually consistent
# release, resolved rather than guessed: the monthly bump job pins torch and
# torchaudio and asks the resolver for the torchvision that matches. The
# unversioned `torch` in ComfyUI's requirements.txt then resolves to the
# already-installed build instead of pulling a CPU or cu126 wheel.
#
# torchaudio, not torch, is the ceiling here. On the cu130 index torch runs
# ahead of torchaudio, so taking the newest torch would mean dropping
# torchaudio entirely. See scripts/dependency-targets.sh.
RUN pip install --upgrade pip \
    && pip install wheel \
    && pip install --index-url "${TORCH_INDEX_URL}" \
        torch==2.11.0 \
        torchvision==0.26.0 \
        torchaudio==2.11.0

WORKDIR /opt
# Clone ComfyUI and install its requirements. ComfyUI pins its own frontend
# packages, so requirements.txt is installed unmodified.
RUN git clone --branch "${COMFYUI_REF}" --depth 1 \
        https://github.com/Comfy-Org/ComfyUI.git "${COMFYUI_PATH}" \
    && pip install -r "${COMFYUI_PATH}/requirements.txt"

# Hardening, applied after requirements.txt because installing it resolves
# setuptools back down to 78.1.0.
#
#   - setuptools: CVE-2025-47273 (path traversal) is fixed in 78.1.1. It cannot
#     simply be removed, because torch declares a dependency on it. The upper
#     bound is torch's own: it requires setuptools<82, so an unconstrained
#     upgrade to 84 would fail pip check.
#   - wheel: not needed at runtime and carries CVE-2026-24049.
#
# Note that msgpack, jaraco.context and vendored urllib3 warnings reported by
# scanners come from copies bundled inside pip and setuptools themselves; those
# are not separately installable and cannot be removed. See README.
RUN pip uninstall -y wheel \
    && pip install --upgrade "setuptools>=78.1.1,<82" \
    && pip check \
    # Fail the build rather than ship a broken dependency set.
    && python -c "import torch, torchvision, comfy_kitchen, transformers"

# The updater runs `git fetch`, which needs a full history and remote refs.
# A shallow clone cannot fast-forward, so deepen it here.
RUN git -C "${COMFYUI_PATH}" fetch --unshallow \
    || git -C "${COMFYUI_PATH}" fetch --depth 1024 origin "${COMFYUI_REF}"

RUN mkdir -p \
        "${COMFYUI_PATH}/models/checkpoints" \
        "${COMFYUI_PATH}/models/vae" \
        "${COMFYUI_PATH}/models/loras" \
        "${COMFYUI_PATH}/models/embeddings" \
        "${COMFYUI_PATH}/models/controlnet" \
        "${COMFYUI_PATH}/models/upscale_models" \
        "${COMFYUI_PATH}/input" \
        "${COMFYUI_PATH}/output" \
        "${COMFYUI_PATH}/custom_nodes" \
    && chown -R "${COMFYUI_UID}:${COMFYUI_GID}" "${COMFYUI_PATH}" /home/comfy

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=0755 comfyui-update.sh /usr/local/bin/comfyui-update

# The updater appends to its log, so it must exist and be writable by the
# unprivileged runtime user.
RUN touch "${UPDATE_LOG}" \
    && chown "${COMFYUI_UID}:${COMFYUI_GID}" "${UPDATE_LOG}"

# ComfyUI needs no Linux capabilities; /dev/nvidia* access comes from the
# container runtime via --gpus, not from privileges. The numeric uid:gid is
# intentional: a literal `USER ${VAR}` would not expand and would create a
# user literally named "${COMFYUI_UID}".
USER ${COMFYUI_UID}:${COMFYUI_GID}
WORKDIR ${COMFYUI_PATH}

EXPOSE 8188

# /system_stats is a cheap, side-effect-free readiness probe. Shell form is
# required because the probe uses a redirect/`||`, and the port is hardcoded
# rather than interpolated because ENV is not expanded inside HEALTHCHECK.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8188/system_stats || exit 1

# tini reaps ComfyUI's children and forwards signals. Without an init, PID 1 is
# the shell and zombies accumulate.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]