#!/usr/bin/env bash
# agent-recover.sh - restore history when the sandbox .git silently reset itself
# back to the baseline commit (seen twice: local HEAD = the initial commit while
# the worktree still holds all of the edits).
#
# Usage:
#     bash skills/git-sync/scripts/agent-recover.sh
#
# Symptom
# -------
#   $ git log --oneline -3
#   6e75159 Initial commit            <-- the baseline again
#   $ git status --short | wc -l
#   42                                <-- every file shows as new/untracked
#
# What it does
# ------------
#   1. make sure refs/remotes/origin/* is fetched (the fetch refspec is often
#      narrow after a reset, so it is set explicitly first)
#   2. move HEAD back onto the working branch with `git reset --mixed`
#      -- the worktree is never touched, so no edit is lost
#   3. report what is now uncommitted, ready for agent-sync.sh
#
# Never re-init the repository and never clone again: both would either lose the
# remote history or create a second, unrelated branch.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

CFG="skills/git-sync/sync.config.json"
BRANCH=""; REMOTE="origin"
if [ -f "$CFG" ]; then
  BRANCH="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('branch',''))" 2>/dev/null || true)"
  REMOTE="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('remote','origin'))" 2>/dev/null || true)"
fi
[ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "== repo   : $REPO_ROOT"
echo "== branch : $BRANCH"
echo "== before : $(git log -1 --oneline 2>/dev/null || echo '(no HEAD)')"
echo "== dirty  : $(git status --porcelain | wc -l) file(s) in the worktree"

# 1) full fetch refspec, then fetch
git config "remote.$REMOTE.fetch" "+refs/heads/*:refs/remotes/$REMOTE/*"
if ! git fetch "$REMOTE"; then
  echo "[ERROR] fetch failed - check the network before recovering" >&2
  exit 3
fi

ORIGIN="$REMOTE/$BRANCH"
if ! git rev-parse --verify --quiet "$ORIGIN" >/dev/null; then
  echo "[ERROR] $ORIGIN does not exist on the remote - refusing to reset" >&2
  exit 3
fi

# 2) keep the worktree, restore HEAD/history
git reset --mixed "$ORIGIN" || { echo "[ERROR] reset failed" >&2; exit 3; }

echo ""
echo "== after  : $(git log -1 --oneline --decorate)"
echo "== dirty  : $(git status --porcelain | wc -l) file(s) - the worktree was NOT touched"
echo ""
echo "next: bash skills/git-sync/scripts/agent-sync.sh \"<commit message>\""
