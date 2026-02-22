#!/bin/bash
set -e

COMFYUI_PATH="${COMFYUI_PATH:-/opt/ComfyUI}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"

setup_huggingface() {
    if [ -n "$HF_TOKEN" ]; then
        echo "[$(date)] Configuring HuggingFace credentials..."
        huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null || \
            echo "[$(date)] Warning: huggingface-cli not available, skipping HF login"
    fi
}

update_comfyui() {
    echo "[$(date)] Checking for ComfyUI updates..."
    cd "${COMFYUI_PATH}"
    
    git fetch origin
    
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse @{u} 2>/dev/null || git rev-parse origin/HEAD)
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        echo "[$(date)] Updates found. Pulling latest changes..."
        git pull --ff-only
        echo "[$(date)] ComfyUI updated successfully."
        
        echo "[$(date)] Updating Python dependencies..."
        pip install -r requirements.txt --quiet
    else
        echo "[$(date)] ComfyUI is already up to date."
    fi
}

if [ "$AUTO_UPDATE" = "true" ]; then
    update_comfyui
fi

setup_huggingface

echo "[$(date)] Starting cron daemon for scheduled updates..."
cron

echo "[$(date)] Starting ComfyUI..."
exec "$@"
