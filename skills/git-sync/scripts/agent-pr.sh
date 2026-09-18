#!/usr/bin/env bash
# agent-pr.sh - the assistant-side PR helper (GitHub CLI).
#
# Usage (from the repo root or anywhere inside it):
#     bash skills/git-sync/scripts/agent-pr.sh                    # PR -> main
#     bash skills/git-sync/scripts/agent-pr.sh --title "..." --body "..."
#     bash skills/git-sync/scripts/agent-pr.sh --base develop
#     bash skills/git-sync/scripts/agent-pr.sh --checks           # CI status
#     bash skills/git-sync/scripts/agent-pr.sh --dry-run          # no side effects
#
# Guards: refuses when the configured branch is main/master, when HEAD is not
# on the configured branch, or when base == head. Needs gh (in the Arena
# sandbox it is already installed and authenticated).
#
# Exit codes: 0 ok, 1 guard error, 3 gh/git error.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

CFG="skills/git-sync/sync.config.json"
BRANCH=""; BASE="main"; TITLE=""; BODY=""; DRY=0; CHECKS=0
if [ -f "$CFG" ]; then
  BRANCH="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('branch',''))" 2>/dev/null || true)"
fi
[ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD)"

while [ $# -gt 0 ]; do
  case "$1" in
    --title)   TITLE="$2"; shift 2 ;;
    --body)    BODY="$2";  shift 2 ;;
    --base)    BASE="$2";  shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --checks)  CHECKS=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$BRANCH" in
  main|master) echo "[REFUSED] the working branch is $BRANCH - nothing to PR" >&2; exit 1 ;;
esac
[ "$BRANCH" = "$BASE" ] && { echo "[REFUSED] base == head == $BASE" >&2; exit 1; }
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT" != "$BRANCH" ] && { echo "[REFUSED] HEAD is $CURRENT, expected $BRANCH" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "[ERROR] gh is not available here" >&2; exit 3; }

echo "== repo   : $REPO_ROOT"
echo "== pr     : $BRANCH -> $BASE"

if [ "$CHECKS" = 1 ]; then
  # checks of the open PR, or the recent workflow runs as a fallback
  if gh pr checks "$BRANCH" 2>/dev/null; then
    exit 0
  fi
  gh run list --branch "$BRANCH" --limit 5
  exit $?
fi

[ -z "$TITLE" ] && TITLE="$(git log -1 --pretty=%s)"
if [ -z "$BODY" ]; then
  BODY="Commits:

$(git log --oneline "$BASE..$BRANCH" 2>/dev/null)"
fi

if [ "$DRY" = 1 ]; then
  echo "== dry run (nothing is created):"
  echo "  gh pr create --base '$BASE' --head '$BRANCH'"
  echo "  --title '$TITLE'"
  echo "  --body  '$(printf '%s' "$BODY" | head -3 | tr '\n' ' ') ...'"
else
  gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY" || {
    echo "[ERROR] pr create failed (one may already be open: gh pr view $BRANCH --web)" >&2
    exit 3
  }
fi
