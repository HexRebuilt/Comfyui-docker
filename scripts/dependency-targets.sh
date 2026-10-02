#!/usr/bin/env bash
# Compute the newest SAFE set of pinned versions, honouring the constraints that
# decide what can actually be bumped together.
#
# Emits shell-eval'able assignments on stdout:
#   CUDA_TARGET=<version>       e.g. 13.4.2
#   TORCH_TARGET=<version>      e.g. 2.12.0   (empty when no safe bump exists)
#   TORCH_AUDIO_TARGET=<version>
#
# "Safe" matters here. Two constraints, both discovered the hard way:
#
#   1. Only the plain -runtime- variant counts for the CUDA base. A
#      -cudnn- or -tensorrt- tag also ends with -runtime-ubuntu24.04, so a
#      suffix match reports a phantom upgrade to an image we do not build.
#   2. torch ships far ahead of torchaudio on the cu130 index. Taking the
#      newest torch when no matching torchaudio exists means dropping
#      torchaudio entirely, so torchaudio -- not torch -- is the ceiling.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMFY_DOCKERFILE="${REPO_ROOT}/Dockerfile"

strip_comments() { grep -vE '^[[:space:]]*#' "$1"; }

pinned_cuda="$(strip_comments "${COMFY_DOCKERFILE}" | grep -oE '^FROM nvidia/cuda:[0-9.]+' | cut -d: -f2)"
# 'cut -d= -f2' on "torch==2.11.0" yields the EMPTY field between the two equals.
pinned_torch="$(strip_comments "${COMFY_DOCKERFILE}" \
    | grep -E '^[[:space:]]*torch==' | head -1 | sed -n 's/.*torch==\([0-9][0-9.]*\).*/\1/p')"

# --- CUDA ------------------------------------------------------------------
# Stay on the same MAJOR version we already ship. A major bump (13 -> 14)
# changes GPU arch support and driver floors, and is a deliberate decision
# rather than something a monthly nudge should make. Minor and patch bumps
# within one major are routine, and torch bundles its own CUDA runtime via pip
# anyway, so the base image is not what pins the CUDA features torch can use.
cuda_series="${pinned_cuda%%.*}"   # 13.0.3 -> 13
cuda_target="$(curl -fsSL \
    "https://hub.docker.com/v2/repositories/nvidia/cuda/tags?page_size=100&name=runtime-ubuntu24.04" \
    2>/dev/null | CUDA_SERIES="$cuda_series" python3 -c '
import json, os, re, sys
series = os.environ["CUDA_SERIES"]
names = [t["name"] for t in json.load(sys.stdin).get("results", [])]
# Anchor on the version boundary: -cudnn-/-tensorrt- variants end with the same
# suffix, so endswith() alone would match them.
pat = re.compile(r"^" + re.escape(series) + r"\.[0-9]+\.[0-9]+-runtime-ubuntu24\.04$")
want = [n for n in names if pat.match(n)]
key = lambda n: [int(x) for x in n.split("-")[0].split(".")]
print(max(want, key=key).split("-")[0] if want else "")' || true)"

# Ask the resolver which torchvision pairs with a given torch/torchaudio.
# Uses the venv inside the published MCP image, so no extra tooling is needed on
# the runner and the resolver sees the same Python 3.12 / cu130 combination the
# image uses. Returns empty if the image cannot be pulled, in which case the
# caller simply skips the torch bump rather than guessing.
#
# Two traps here, both hit and fixed during testing:
#   - uv writes its resolution to STDERR, so the 2>&1 is load-bearing; without
#     it the version list is discarded and the lookup always returns empty.
#   - 'cut -d= -f2' on "torchvision==0.26.0" yields the EMPTY field between the
#     two equals, so the version parses as blank. sed is used instead.
resolve_triple() { # torch_version
    local out
    out="$(docker run --rm --entrypoint uv \
        ghcr.io/hexrebuilt/comfyui-docker-mcp:latest \
        pip install --dry-run --system --python /usr/local/bin/python3 \
        --index-url https://download.pytorch.org/whl/cu130 \
        "torch==$1" torchvision "torchaudio==$1" 2>&1 \
        | grep -oE 'torchvision==[0-9.]+' | head -1 | sed 's/.*==//')"
    printf '%s' "${out}"
}

# --- torch / torchaudio ---------------------------------------------------
# Newest torch that ALSO has a matching torchaudio on the same CUDA index.
torch_audio="$(curl -fsSL https://download.pytorch.org/whl/cu130/torchaudio/ 2>/dev/null \
    | grep -oE 'torchaudio-[0-9.]+\+cu130-cp312-cp312-manylinux_2_28_x86_64\.whl' \
    | grep -oE 'torchaudio-[0-9.]+' | cut -d- -f2 | sort -uV | tail -1)"
torch_newest="$(curl -fsSL https://download.pytorch.org/whl/cu130/torch/ 2>/dev/null \
    | grep -oE 'torch-[0-9.]+\+cu130-cp312-cp312-manylinux_2_28_x86_64\.whl' \
    | grep -oE 'torch-[0-9.]+' | cut -d- -f2 | sort -uV | tail -1)"

# torchvision must be resolved, never guessed. The mapping from torch to
# torchvision is not derivable from the version number (torch 2.11.0 pairs with
# torchvision 0.26.0, not with 0.29.1 which is the newest on the index), so ask
# the resolver instead: pin torch and torchaudio, leave torchvision unpinned,
# and it picks the only torchvision compatible with that torch.
torch_target=""
TORCHVISION_TARGET=""
if [ -n "${torch_audio}" ] && [ -n "${pinned_torch}" ]; then
    if [ "${torch_audio}" != "${pinned_torch}" ]; then
        resolved="$(resolve_triple "${torch_audio}" || true)"
        if [ -n "${resolved}" ]; then
            torch_target="${torch_audio}"
            TORCHVISION_TARGET="${resolved}"
        fi
    fi
fi

printf 'CUDA_TARGET=%s\n' "${cuda_target:-}"
printf 'TORCH_TARGET=%s\n' "${torch_target:-}"
printf 'TORCHVISION_TARGET=%s\n' "${TORCHVISION_TARGET:-}"
printf 'TORCH_AUDIO_TARGET=%s\n' "${torch_audio:-}"
printf 'TORCH_NEWEST_ON_INDEX=%s\n' "${torch_newest:-}"
printf 'PINNED_CUDA=%s\n' "${pinned_cuda:-}"
printf 'PINNED_TORCH=%s\n' "${pinned_torch:-}"