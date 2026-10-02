#!/bin/bash
# Entrypoint for the ComfyUI MCP server container.
#
# Refreshes comfy-mcp / comfy-cli, then hands off to the MCP server.
#
# The refresh happens at STARTUP, before the MCP handshake, and never during a
# session. That is the important distinction from the ComfyUI container: this one
# is spawned fresh for every MCP session, so updating before the handshake means
# each session runs a known-current version without any risk of swapping code
# underneath a live conversation.
set -uo pipefail

AUTO_UPDATE="${AUTO_UPDATE:-true}"
UPDATE_LOG=/var/log/mcp-update.log

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${UPDATE_LOG}"; }

# Point comfy-cli at the baked ComfyUI workspace. Done here as the runtime user
# rather than at build time, because comfy-cli writes its config under $HOME and
# a root-owned /root/.config would be ignored at runtime.
if [ -d "${COMFY_WORKSPACE:-}" ]; then
    current="$(comfy which 2>/dev/null || true)"
    case "${current}" in
        *"${COMFY_WORKSPACE}"*) : ;;
        *)
            log "Setting comfy-cli workspace to ${COMFY_WORKSPACE}"
            comfy set-default "${COMFY_WORKSPACE}" >/dev/null 2>&1 \
                || log "Warning: could not set the workspace; node and node-dependency tools will fail"
            ;;
    esac
fi

# Latest published version on PyPI, or empty if the lookup failed.
pypi_latest() {
    python - "$1" <<'PY' 2>/dev/null
import json, sys, urllib.request
try:
    with urllib.request.urlopen(f"https://pypi.org/pypi/{sys.argv[1]}/json", timeout=20) as r:
        print(json.load(r)["info"]["version"])
except Exception:
    pass
PY
}

installed() { python -c "import importlib.metadata as m,sys; print(m.version(sys.argv[1]))" "$1" 2>/dev/null; }

if [ "${AUTO_UPDATE}" = "true" ]; then
    want_mcp="$(pypi_latest comfy-mcp)"
    want_cli="$(pypi_latest comfy-cli)"
    have_mcp="$(installed comfy-mcp)"
    have_cli="$(installed comfy-cli)"

    # Only reinstall when something is actually newer, so a normal start costs
    # two small HTTP requests rather than a full dependency resolve.
    if [ -n "${want_mcp}" ] && [ "${want_mcp}" != "${have_mcp}" ]; then
        log "Updating comfy-mcp ${have_mcp:-none} -> ${want_mcp}"
        if pip install --no-cache-dir --upgrade "comfy-mcp==${want_mcp}"; then
            have_mcp="${want_mcp}"
        else
            # A failed update must not stop the server from starting; the
            # currently installed version is very likely still usable.
            log "comfy-mcp update failed; continuing with ${have_mcp:-unknown}"
        fi
    fi

    if [ -n "${want_cli}" ] && [ "${want_cli}" != "${have_cli}" ]; then
        log "Updating comfy-cli ${have_cli:-none} -> ${want_cli}"
        if pip install --no-cache-dir --upgrade "comfy-cli==${want_cli}"; then
            have_cli="${want_cli}"
        else
            log "comfy-cli update failed; continuing with ${have_cli:-unknown}"
        fi
    fi

    log "Serving comfy-mcp ${have_mcp:-unknown} / comfy-cli ${have_cli:-unknown}"
else
    log "AUTO_UPDATE=false; serving the versions baked into the image"
fi

# `comfy-mcp` is stdio: it reads MCP on stdin and writes to stdout. Anything this
# script printed above has already gone to stdout, which is fine before the
# handshake, but nothing further may be written to it once the server runs.
exec comfy-mcp "$@"