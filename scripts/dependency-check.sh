#!/usr/bin/env bash
# Monthly upstream dependency check. Read-only: reports, never changes anything.
#
# Called by .github/workflows/dependency-watch.yml. Kept as a script rather than
# inline YAML so it can be run and tested locally:
#
#   ./scripts/dependency-check.sh
#
# Exit status is always 0; the interesting result is printed, and `drift=1` is
# emitted on stdout so the caller can act on it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMFY_DOCKERFILE="${REPO_ROOT}/Dockerfile"
MCP_DOCKERFILE="${REPO_ROOT}/Dockerfile.mcp"
# /dev/stdout is not always a writable device (it is not, for example, when the
# script is piped). Fall back to a temp file so the summary never breaks a run.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    SUMMARY="${GITHUB_STEP_SUMMARY}"
else
    SUMMARY="$(mktemp)"
    trap 'rm -f "${ROWS}" "${SUMMARY}"' EXIT
fi

# Strip comment lines before reading pins out of the Dockerfiles. Without this a
# prose mention of "torch==2.11.0" in a comment is indistinguishable from the
# real pin, which is how this script first reported an empty version.
strip_comments() { grep -vE '^[[:space:]]*#' "$1"; }

ROWS="$(mktemp)"
trap 'rm -f "${ROWS}"' EXIT
drift=0

{
    echo "## Upstream dependency check"
    echo ""
    echo "| Component | Pinned / installed | Upstream latest | Status |"
    echo "|---|---|---|---|"
} >>"${SUMMARY}"

# The backticks are literal markdown code spans, not command substitution, so
# they must NOT expand. SC2016 flags exactly that, and is wrong here.
# shellcheck disable=SC2016
row() { # name pinned latest status
    printf '| %s | `%s` | `%s` | %s |\n' "$1" "$2" "$3" "$4" >>"${ROWS}"
}

pypi_latest() {
    curl -fsSL "https://pypi.org/pypi/$1/json" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' \
        || echo "unknown"
}

gh_latest_release() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","unknown"))' \
        || echo "unknown"
}

# Newest version on the cu130 wheel index, matching the cp312 linux wheel this
# image actually installs.
index_latest() { # torch|torchaudio
    curl -fsSL "https://download.pytorch.org/whl/cu130/$1/" 2>/dev/null \
        | grep -oE "$1-[0-9.]+\+cu130-cp312-cp312-manylinux_2_28_x86_64\.whl" \
        | grep -oE "$1-[0-9.]+" | cut -d- -f2 | sort -uV | tail -1
}

# --- 1. comfy-mcp / comfy-cli --------------------------------------------
# These float by design: the MCP container upgrades itself at startup and its
# image is rebuilt weekly, so a newer release needs no action here.
pinned_mcp="$(strip_comments "${MCP_DOCKERFILE}" | grep -oE '^ARG COMFY_MCP_SPEC=[^ ]*' | cut -d= -f2 || true)"
# Trim the '>=VERSION' constraint off the spec: report the package, not the spec.
pinned_cli="$(strip_comments "${MCP_DOCKERFILE}" | grep -oE '^ARG COMFY_CLI_SPEC=[^ ]+' \
    | cut -d= -f2- | sed 's/>=.*//' || true)"
row "comfy-mcp" "${pinned_mcp:-unpinned}" "$(pypi_latest comfy-mcp)" \
    "auto-updated at container start; no action needed"
row "comfy-cli" "${pinned_cli:-unpinned}" "$(pypi_latest comfy-cli)" \
    "auto-updated at container start; no action needed"

# --- 2. ComfyUI ----------------------------------------------------------
# Also self-updating: AUTO_UPDATE=true fast-forwards to upstream master.
row "ComfyUI" "master, self-updating at runtime" "$(gh_latest_release Comfy-Org/ComfyUI)" \
    "already tracks upstream; no action needed"

# --- 3. CUDA base image (pinned, needs a rebuild) ------------------------
pinned_cuda="$(strip_comments "${COMFY_DOCKERFILE}" | grep -oE '^FROM nvidia/cuda:[0-9.]+' | cut -d: -f2)"
newest_cuda="$(curl -fsSL \
    "https://hub.docker.com/v2/repositories/nvidia/cuda/tags?page_size=100&name=runtime-ubuntu24.04" \
    2>/dev/null | python3 -c '
import json, re, sys
names = [t["name"] for t in json.load(sys.stdin).get("results", [])]
# Exactly "-runtime-", not "-cudnn-" or "-tensorrt-": this image pins the plain
# runtime variant, so a cudnn or tensorrt tag must not count as an upgrade.
# Only the plain "-runtime-" variant counts. Our FROM line pins
# nvidia/cuda:<ver>-runtime-ubuntu24.04; matching "-cudnn-" or "-tensorrt-"
# here would report a phantom upgrade to a variant we do not build.
# Anchor on the version boundary, not endswith: "13.4.2-tensorrt-runtime-ubuntu24.04"
# ALSO ends with "-runtime-ubuntu24.04", so a suffix match alone reports a phantom
# upgrade to a variant this image does not build.
pat = re.compile(r"^13\.[0-9.]+-runtime-ubuntu24\.04$")
want = [n for n in names if pat.match(n)]
key = lambda n: [int(x) for x in n.split("-")[0].split(".")]
print(max(want, key=key) if want else "unknown")' || echo unknown)"
newest_cuda_ver="${newest_cuda%%-*}"
if [ -z "${pinned_cuda}" ] || [ "${newest_cuda_ver}" = "unknown" ]; then
    row "nvidia/cuda (base)" "${pinned_cuda:-not found}" "${newest_cuda}" "could not check"
elif [ "${newest_cuda_ver}" != "${pinned_cuda}" ]; then
    drift=1
    row "nvidia/cuda (base)" "$pinned_cuda" "$newest_cuda" "**behind** - rebuild to pick up"
else
    row "nvidia/cuda (base)" "$pinned_cuda" "$newest_cuda" "current"
fi

# --- 4. torch / torchaudio ------------------------------------------------
# torchaudio is the constraint that actually decides this, not torch. torch runs
# far ahead of torchaudio on the cu130 index, and taking a torch release with no
# matching torchaudio means dropping torchaudio entirely.
# Anchor to the pip install line so the pin is read from the install command,
# not from any stray mention elsewhere in the file.
# sed, not 'cut -d= -f2': the string is "torch==2.11.0", so cutting on '=' yields
# the EMPTY field between the two equals. That bug made this report a blank pin.
torch_pinned="$(strip_comments "${COMFY_DOCKERFILE}" \
    | grep -E '^[[:space:]]*torch==' | head -1 | sed -n 's/.*torch==\([0-9][0-9.]*\).*/\1/p')"
torch_new="$(index_latest torch || true)"
audio_new="$(index_latest torchaudio || true)"
if [ -z "${audio_new}" ]; then
    row "torch / torchaudio (cu130)" "${torch_pinned:-not found}" "${torch_new:-unknown}" \
        "could not check the torchaudio index"
elif [ "${audio_new}" != "${torch_pinned}" ]; then
    drift=1
    row "torch / torchaudio (cu130)" "$torch_pinned" "$audio_new" \
        "**bump available** - a matching torchaudio now exists; verify on GPU before merging"
else
    row "torch / torchaudio (cu130)" "$torch_pinned" "${torch_new:-unknown}" \
        "current - torch is at ${torch_new:-unknown} but torchaudio caps at ${audio_new}, so ${torch_pinned} is correct"
fi

cat "${ROWS}" >>"${SUMMARY}"
{
    echo ""
    echo "ComfyUI, comfy-mcp and comfy-cli update themselves. The last two rows are"
    echo "pinned in the Dockerfile and need a rebuild plus a GPU check - a torch bump"
    echo "is exactly the change that can silently break a GPU architecture."
    echo ""
    echo "_Checked $(date -u '+%Y-%m-%d %H:%M UTC')._"
} >>"${SUMMARY}"

cat "${ROWS}"
echo "drift=${drift}"
