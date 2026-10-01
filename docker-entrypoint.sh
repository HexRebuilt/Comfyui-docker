#!/bin/bash
# Entrypoint for the ComfyUI container.
#
# Responsibilities:
#   1. Optionally pull the latest ComfyUI + Python deps at startup.
#   2. Optionally start a background loop that repeats that on an interval.
#   3. Configure HuggingFace credentials if a token was supplied.
#   4. Hand off to ComfyUI.
set -euo pipefail

COMFYUI_PATH="${COMFYUI_PATH:-/opt/ComfyUI}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
UPDATE_INTERVAL="${UPDATE_INTERVAL:-}"
UPDATE_SCRIPT=/usr/local/bin/comfyui-update
UPDATE_LOG=/var/log/comfyui-update.log

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# HF CLI is `hf` in huggingface_hub >= 1.0; `huggingface-cli` was removed.
# Probe both so the image keeps working across hub versions.
hf_login() {
    if command -v hf >/dev/null 2>&1; then
        hf auth login --token "$1" --add-to-git-credential
    elif command -v huggingface-cli >/dev/null 2>&1; then
        huggingface-cli login --token "$1" --add-to-git-credential
    else
        echo "no hf CLI found; skipping HuggingFace login" >&2
        return 1
    fi
}

if [ "${AUTO_UPDATE}" = "true" ]; then
    log "Checking for ComfyUI updates (startup)"
    # A failed update must not stop the container from starting: the installed
    # ComfyUI is very likely still usable, and refusing to boot would turn a
    # network problem into an outage.
    if ! "${UPDATE_SCRIPT}" 2>&1 | tee -a "${UPDATE_LOG}"; then
        log "Update check failed; starting with the currently installed version"
    fi
else
    log "AUTO_UPDATE is false; skipping the startup update check"
fi

# HF_TOKEN is also read directly by huggingface_hub at runtime, so this step is
# only for CLI tooling and custom nodes that use the stored credentials file.
if [ -n "${HF_TOKEN:-}" ]; then
    log "Configuring HuggingFace credentials"
    hf_login "${HF_TOKEN}" || log "HuggingFace login skipped"
else
    log "HF_TOKEN not set; using anonymous HuggingFace access"
fi

if [ "${ENABLE_CRON:-true}" != "true" ] || [ "${AUTO_UPDATE}" != "true" ] || [ -z "${UPDATE_INTERVAL}" ]; then
    log "Scheduled updates disabled (AUTO_UPDATE=${AUTO_UPDATE}, ENABLE_CRON=${ENABLE_CRON:-true}, UPDATE_INTERVAL=${UPDATE_INTERVAL:-unset})"
else
    log "Scheduled updates every ${UPDATE_INTERVAL}"
    # A background loop rather than a cron daemon: Debian's cron refuses to run
    # as non-root, and this image is deliberately unprivileged. supercronic
    # would work but can only run crontab jobs, so it would have to become PID 1
    # and ComfyUI would lose direct signal handling.
    #
    # No nohup/setsid: exec below replaces this shell, so the subshell is
    # reparented to tini (PID 1) and keeps running for the container's life.
    (
        while true; do
            sleep "${UPDATE_INTERVAL}"
            "${UPDATE_SCRIPT}" >>"${UPDATE_LOG}" 2>&1 || true
        done
    ) &
fi

log "Starting ComfyUI: $*"
exec "$@"