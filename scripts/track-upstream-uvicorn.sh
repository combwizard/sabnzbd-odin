#!/usr/bin/env bash
# Report divergence between develop and upstream feature/uvicorn (PR #3373).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REMOTE="${SAB_UPSTREAM_REMOTE:-origin}"
BRANCH="${SAB_UPSTREAM_UVICORN_BRANCH:-feature/uvicorn}"
LOCAL_BRANCH="${SAB_LOCAL_BRANCH:-develop}"

echo "Fetching ${REMOTE}/${BRANCH}..."
git fetch "$REMOTE" "$BRANCH"

BASE="$(git merge-base "$LOCAL_BRANCH" "$REMOTE/$BRANCH")"
read -r BEHIND AHEAD < <(git rev-list --left-right --count "$LOCAL_BRANCH"..."$REMOTE/$BRANCH")

echo
echo "Upstream uvicorn migration: ${REMOTE}/${BRANCH}"
echo "Local branch: ${LOCAL_BRANCH}"
echo "Merge base: $(git log -1 --oneline "$BASE")"
echo "Divergence: ${AHEAD} ahead, ${BEHIND} behind (local...upstream)"
echo

if COMMITS="$(git log --oneline "$LOCAL_BRANCH..$REMOTE/$BRANCH" | head -5)" && [[ -n "$COMMITS" ]]; then
    echo "Recent upstream commits not in ${LOCAL_BRANCH}:"
    echo "$COMMITS"
    MORE="$(git rev-list --count "$LOCAL_BRANCH..$REMOTE/$BRANCH")"
    if [[ "$MORE" -gt 5 ]]; then
        echo "... and $((MORE - 5)) more"
    fi
    echo
fi

MERGE_OUT="$(git merge-tree "$BASE" "$LOCAL_BRANCH" "$REMOTE/$BRANCH" 2>/dev/null || true)"
CONFLICTS="$(printf '%s\n' "$MERGE_OUT" | grep -c '^<<<<<<<' || true)"
OVERLAP="$(printf '%s\n' "$MERGE_OUT" | awk '/^changed in both/{c++} END{print c+0}')"
echo "Simulated merge: ${OVERLAP} files changed in both sides, ${CONFLICTS} unresolved conflict hunks"
echo
echo "Odin touch points after merge (see .cursor/docs/ODIN-INTEGRATION.md):"
echo "  sabnzbd/odin_api.py          — keep as-is"
echo "  sabnzbd/api.py               — re-wire call sites + report(kwargs, ...)"
echo "  tests/test_api_odin.py       — run unit tests"
