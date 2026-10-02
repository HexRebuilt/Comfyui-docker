#!/usr/bin/env bash
# Apply a dependency bump to Dockerfile in place.
#
#   ./scripts/apply-bump.sh <cuda_ver> <torch_ver> <torchvision_ver>
#
# Blank arguments mean "leave alone", so the caller can bump CUDA without also
# touching torch. Exits 0 without editing anything when nothing was requested,
# which is what the monthly run relies on to stay a no-op when already current.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile"

cuda="${1:-}"
torch="${2:-}"
vision="${3:-}"

if [ -z "${cuda}" ] && [ -z "${torch}" ]; then
    echo "Nothing to bump."
    exit 0
fi

before="$(cat "${DOCKERFILE}")"

if [ -n "${cuda}" ]; then
    # Patch the FROM line only, leaving the rest of the tag (variant, ubuntu
    # version) exactly as it was.
    sed -i -E "s|^(FROM nvidia/cuda:)[0-9]+\.[0-9]+\.[0-9]+|\1${cuda}|" "${DOCKERFILE}"
fi

if [ -n "${torch}" ]; then
    # Anchor on the leading whitespace of the install lines so only the pinned
    # versions change and the surrounding command is untouched.
    sed -i -E "s|^([[:space:]]*)torch==[0-9]+\.[0-9]+\.[0-9]+([[:space:]]*\\\\)?$|\1torch==${torch}\2|" "${DOCKERFILE}"
    sed -i -E "s|^([[:space:]]*)torchvision==[0-9]+\.[0-9]+\.[0-9]+([[:space:]]*\\\\)?$|\1torchvision==${vision}\2|" "${DOCKERFILE}"
    sed -i -E "s|^([[:space:]]*)torchaudio==[0-9]+\.[0-9]+\.[0-9]+([[:space:]]*\\\\)?$|\1torchaudio==${torch}\2|" "${DOCKERFILE}"
    # The explanatory comment deliberately carries no version numbers, so there
    # is nothing here to keep in sync. An earlier version repeated them and went
    # stale the first time the pins moved.
fi

if [ "$(cat "${DOCKERFILE}")" = "${before}" ]; then
    echo "WARNING: bump requested but the Dockerfile did not change." >&2
    exit 1
fi

echo "Bumped:"
[ -n "${cuda}" ] && echo "  nvidia/cuda -> ${cuda}"
[ -n "${torch}" ] && echo "  torch/torchvision/torchaudio -> ${torch}/${vision}"

git -C "${REPO_ROOT}" diff --stat -- Dockerfile