#!/usr/bin/env bash
# Open a PR aligning the Dockerfile's pinned CUDA/torch versions with upstream,
# then enable auto-merge so it lands once CI is green.
#
#   ./scripts/align-upstream.sh            # dry run: report only, change nothing
#   .//scripts/align-upstream.sh --apply    # actually branch, commit, push, PR
#
# Requires: git, gh (authenticated), docker, and a shell that can run the repo's
# scripts. Assumes it is being run from a checkout with the default branch
# checked out and a clean tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# --- resolve the newest safe targets --------------------------------------
# shellcheck disable=SC1091
eval "$(./scripts/dependency-targets.sh)"

echo "Resolved targets:"
echo "  nvidia/cuda            ${PINNED_CUDA:-?} -> ${CUDA_TARGET:-no bump}"
echo "  torch                  ${PINNED_TORCH:-?} -> ${TORCH_TARGET:-no bump}"
echo "  torchaudio ceiling     ${TORCH_AUDIO_TARGET:-?}"
echo "  newest torch on index  ${TORCH_NEWEST_ON_INDEX:-?}"
echo "  pinned_cuda=${PINNED_CUDA:-} pinned_torch=${PINNED_TORCH:-} cuda=${CUDA_TARGET:-} torch=${TORCH_TARGET:-} vision=${TORCHVISION_TARGET:-}"

if [ -z "${CUDA_TARGET:-}" ] && [ -z "${TORCH_TARGET:-}" ]; then
    echo
    echo "Already aligned with upstream. Nothing to do."
    exit 0
fi

# Nothing to do when the "new" target is not actually newer than the pin.
version_gt() { # a b  -> true when a > b
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}
if [ -n "${CUDA_TARGET:-}" ] && ! version_gt "${CUDA_TARGET}" "${PINNED_CUDA:-0}"; then
    echo "  CUDA target ${CUDA_TARGET} is not newer than the pin; ignoring."
    CUDA_TARGET=""
fi
if [ -n "${TORCH_TARGET:-}" ] && ! version_gt "${TORCH_TARGET}" "${PINNED_TORCH:-0}"; then
    echo "  torch target ${TORCH_TARGET} is not newer than the pin; ignoring."
    TORCH_TARGET=""
    TORCHVISION_TARGET=""
fi

if [ -z "${CUDA_TARGET:-}" ] && [ -z "${TORCH_TARGET:-}" ]; then
    echo
    echo "Nothing newer available. Nothing to do."
    exit 0
fi

if [ "${APPLY}" -ne 1 ]; then
    echo
    echo "Dry run. Re-run with --apply to branch, commit and open the PR."
    exit 0
fi

# --- branch, bump, commit --------------------------------------------------
branch="automation/align-$(date -u '+%Y-%m')"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -b "${branch}"

./scripts/apply-bump.sh "${CUDA_TARGET:-}" "${TORCH_TARGET:-}" "${TORCHVISION_TARGET:-}"

if git diff --quiet -- Dockerfile; then
    echo "ERROR: bump produced no change; refusing to open an empty PR." >&2
    exit 1
fi

git add Dockerfile
git commit -q -F - <<EOF
chore(deps): align pinned CUDA and torch with upstream

Monthly automated alignment from dependency-watch.yml.

- nvidia/cuda: ${PINNED_CUDA} -> ${CUDA_TARGET:-unchanged}
- torch: ${PINNED_TORCH} -> ${TORCH_TARGET:-unchanged}${TORCHVISION_TARGET:+ (torchvision ${TORCHVISION_TARGET})}

torchaudio is the ceiling on the torch version. It is the constraint the
bump job resolves against, so this cannot move torch past the point where a
matching torchaudio exists on the cu130 index.

The build fails if the resulting torch has no sm_86/sm_120 kernels, so a
combination that cannot target the target GPUs cannot merge.
EOF

git push -u origin "${branch}"

# --- PR + auto-merge ------------------------------------------------------
read -r -d '' pr_body <<EOF || true
Automated monthly alignment, opened by [\`dependency-watch.yml\`](${SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-HexRebuilt/Comfyui-docker}/actions/runs/${GITHUB_RUN_ID:-local}).

| Component | From | To |
|---|---|---|
| \`nvidia/cuda\` | \`${PINNED_CUDA}\` | \`${CUDA_TARGET:-unchanged}\` |
| \`torch\` | \`${PINNED_TORCH}\` | \`${TORCH_TARGET:-unchanged}\` |

\`torchaudio\` is the constraint on the torch version; the bump is skipped when no
matching \`torchaudio\` exists on the cu130 index (it is currently at
\`${TORCH_AUDIO_TARGET}\` while torch is at \`${TORCH_NEWEST_ON_INDEX}\`).

This merges itself once CI is green. The build fails if the resulting torch has
no \`sm_86\`/\`sm_120\` kernels, so a combination that cannot target the target GPUs
cannot land.
EOF

pr_url="$(gh pr create --base master --head "${branch}" \
    --title "chore(deps): align CUDA/torch with upstream" \
    --body "${pr_body}")"

echo "Opened ${pr_url}"

# Auto-merge is what makes this "automagically": it lands on its own once every
# required check passes, and a red build simply stops here.
#
# SAFETY: `gh pr merge --auto` is only safe when auto-merge is enabled on the
# repo. When it is NOT enabled, gh silently performs an IMMEDIATE merge instead
# of refusing - which was observed here, and merged a CUDA bump while its checks
# were still pending. So the result is verified rather than trusted.
#
# Never fall back to a plain merge here. If auto-merge cannot be enabled, say so
# and leave the PR for a human.
pr_number="$(gh pr view "${pr_url}" --json number --jq .number)"
auto_before="$(gh pr view "${pr_url}" --json autoMergeRequest --jq '.autoMergeRequest != null')"

if gh pr merge "${pr_url}" --squash --auto >/dev/null 2>&1; then
    auto_after="$(gh pr view "${pr_url}" --json autoMergeRequest,state \
        --jq 'if .autoMergeRequest != null then "armed" else .state end')"
    if [ "${auto_after}" = "armed" ]; then
        echo "Auto-merge armed on #${pr_number}; it merges only once checks pass."
    elif [ "${auto_after}" = "MERGED" ] && [ "${auto_before}" = "true" ]; then
        echo "PR #${pr_number} already merged with auto-merge set."
    else
        echo "::error::gh reported success but auto-merge is NOT armed on #${pr_number}." >&2
        echo "::error::Refusing to leave an unarmed bump PR. Review it manually:" >&2
        echo "::error::${pr_url}" >&2
        exit 1
    fi
else
    echo "::warning::Auto-merge is not enabled for this repository, so gh would"
    echo "::warning::merge ${pr_url} immediately rather than after checks."
    echo "::warning::Leaving the PR open for a human instead."
    echo "::warning::Enable it with:"
    echo "::warning::  gh api --method PATCH repos/${GITHUB_REPOSITORY:-<owner/repo>} -F allow_auto_merge=true"
    echo "::warning::or merge manually once checks are green: ${pr_url}"
fi