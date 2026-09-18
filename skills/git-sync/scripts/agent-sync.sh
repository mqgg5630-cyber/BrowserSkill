#!/usr/bin/env bash
# agent-sync.sh - the assistant-side "commit + push" for one round of work.
#
# Usage (from the repo root or anywhere inside it):
#     bash skills/git-sync/scripts/agent-sync.sh "feat: ..."            # commit + push
#     bash skills/git-sync/scripts/agent-sync.sh "feat: ..." --no-gate  # skip the checks
#     bash skills/git-sync/scripts/agent-sync.sh --status               # just report
#
# What it does, in order:
#   1. branch guard   - refuses to run on main/master and refuses to touch any
#                       branch other than the one in sync.config.json
#   2. fetch          - always refresh refs/remotes/origin/* first
#   3. sanity check   - if HEAD is not a descendant of origin/<branch> (the
#                       sandbox .git silently resetting to the baseline commit
#                       does exactly this), run agent-recover.sh logic inline so
#                       the worktree is kept and history is restored
#   4. gate           - run the "gate" command from sync.config.json
#                       (default: bash code/check_all.sh), abort on failure
#   5. receipt        - write the sync report (config key "receipt", e.g.
#                       results/sync/last_sync.md): which local commits were
#                       picked up, what this round changes (diff stat)
#   6. commit + push  - git add -A, commit with the given message, push to the
#                       configured branch only
#
# Exit codes: 0 ok, 1 usage/guard error, 2 gate failed, 3 git error.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

CFG="skills/git-sync/sync.config.json"
BRANCH=""; REMOTE="origin"; GATE="bash code/check_all.sh"; RECEIPT=""; RECEIPT_HIST="results/sync/history"
if [ -f "$CFG" ]; then
  BRANCH="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('branch',''))" 2>/dev/null || true)"
  REMOTE="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('remote','origin'))" 2>/dev/null || true)"
  GATE_CFG="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('gate',''))" 2>/dev/null || true)"
  RECEIPT="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('receipt',''))" 2>/dev/null || true)"
  RECEIPT_HIST="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('receipt_history','results/sync/history'))" 2>/dev/null || true)"
  [ -n "$GATE_CFG" ] && GATE="$GATE_CFG"
fi
[ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD)"

MSG=""; RUN_GATE=1
for arg in "$@"; do
  case "$arg" in
    --no-gate) RUN_GATE=0 ;;
    --status)  MSG="__status__" ;;
    -*)        echo "unknown option: $arg" >&2; exit 1 ;;
    *)         MSG="$arg" ;;
  esac
done

echo "== repo  : $REPO_ROOT"
echo "== branch: $BRANCH (remote $REMOTE)"
echo "== gate  : $([ "$RUN_GATE" = 1 ] && echo "$GATE" || echo '(skipped)')"

# ---------------------------------------------------------------- 1. guard
case "$BRANCH" in
  main|master) echo "[REFUSED] never work on $BRANCH - set branch in $CFG" >&2; exit 1 ;;
esac
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT" != "$BRANCH" ]; then
  echo "[REFUSED] HEAD is on $CURRENT, expected $BRANCH" >&2
  echo "          this session must stay on its own branch" >&2
  exit 1
fi

# ---------------------------------------------------------------- 2. fetch
# a sandbox .git reset often leaves a narrow fetch refspec behind, which hides
# the remote branch and would silently disable the self-heal below - fix it
git config "remote.$REMOTE.fetch" "+refs/heads/*:refs/remotes/$REMOTE/*"
if ! git fetch "$REMOTE" 2>&1 | tail -2; then
  echo "[ERROR] git fetch failed" >&2; exit 3
fi
ORIGIN="$REMOTE/$BRANCH"

# commits the local side pushed since our last round (user -> agent direction)
USER_COMMITS="$(git log --oneline "HEAD..$ORIGIN" 2>/dev/null || true)"

status_report() {
  echo "-- HEAD        : $(git log -1 --oneline)"
  echo "-- $ORIGIN : $(git log -1 --oneline "$ORIGIN" 2>/dev/null || echo '(not fetched yet)')"
  echo "-- uncommitted : $(git status --porcelain | wc -l) file(s)"
  echo "-- stash       : $(git stash list | wc -l) entr(y|ies)"
}

if [ "${MSG:-}" = "__status__" ]; then
  status_report
  exit 0
fi

# ------------------------------------------------- 3. divergence / recovery
if git rev-parse --verify --quiet "$ORIGIN" >/dev/null; then
  if ! git merge-base --is-ancestor HEAD "$ORIGIN" 2>/dev/null \
     && ! git merge-base --is-ancestor "$ORIGIN" HEAD 2>/dev/null; then
    echo "!! HEAD and $ORIGIN have diverged (the sandbox .git reset to the baseline commit does this)."
    echo "   keeping the worktree, moving HEAD onto $ORIGIN ..."
    git reset --mixed "$ORIGIN" || { echo "[ERROR] recovery failed" >&2; exit 3; }
    git ls-files -d | xargs -r git checkout --
  elif git merge-base --is-ancestor HEAD "$ORIGIN" 2>/dev/null; then
    BEHIND="$(git rev-list --count "HEAD..$ORIGIN")"
    if [ "$BEHIND" != "0" ]; then
      echo "!! $BEHIND commit(s) behind $ORIGIN - fast-forwarding"
      git reset --mixed "$ORIGIN" || { echo "[ERROR] fast-forward failed" >&2; exit 3; }
      git ls-files -d | xargs -r git checkout --
    fi
  fi
fi

# ---------------------------------------------------------------- 4. gate
if [ "$RUN_GATE" = 1 ] && [ -n "$GATE" ]; then
  echo "== gate: $GATE"
  if ! bash -c "$GATE"; then
    echo "[GATE FAILED] nothing was committed. Fix the checks first." >&2
    exit 2
  fi
fi

# --------------------------------------------- 5. receipt (the sync report)
# one markdown file the user can read after .\sync.ps1 to see what this round
# changed and which of their commits were picked up (config key: "receipt")
CHANGED="$(git status --porcelain)"
HAD_CHANGES=0; [ -n "$CHANGED" ] && HAD_CHANGES=1
if [ -n "$RECEIPT" ] && { [ -n "$CHANGED" ] || [ -n "$USER_COMMITS" ]; }; then
  RECEIPT_NORM="${RECEIPT//\\//}"
  mkdir -p "$(dirname "$RECEIPT_NORM")"
  {
    echo "# 最近一轮同步回执（agent -> 分支）"
    echo ""
    echo "- 时间：$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "- 分支：\`$BRANCH\`"
    if [ -n "$USER_COMMITS" ]; then
      echo "- 本轮纳入的**本机侧**提交（本机 -> 助手 ✅）："
      printf '%s\n' "$USER_COMMITS" | grep '.' | sed 's/^/  - /'
    fi
    if [ -n "${MSG:-}" ] && [ "$MSG" != "__status__" ]; then
      echo "- 本轮助手提交：$MSG"
    fi
    if [ -n "$CHANGED" ]; then
      echo "- 本轮改动文件："
      printf '%s\n' "$CHANGED" | grep -v -F "$RECEIPT_NORM" | grep '.' | sed 's/^/  /'
    fi
    echo ""
    echo "> 完整历史：\`git log --oneline -10\`；本机 \`.\\sync.ps1\` 之后即可看到本文件。"
  } > "$RECEIPT_NORM"
  echo "== receipt: $RECEIPT_NORM"
  # archive a dated copy (config key: receipt_history, empty = off; newest 50 kept)
  if [ -n "$RECEIPT_HIST" ]; then
    RECEIPT_HIST_NORM="${RECEIPT_HIST//\\//}"
    mkdir -p "$RECEIPT_HIST_NORM"
    HIST_FILE="$RECEIPT_HIST_NORM/$(date -u '+%Y%m%d-%H%M%S').md"
    cp "$RECEIPT_NORM" "$HIST_FILE"
    ls -1 "$RECEIPT_HIST_NORM" 2>/dev/null | sort -r | tail -n +51 | \
      while IFS= read -r old; do rm -f "$RECEIPT_HIST_NORM/$old"; done
    echo "== archived: $HIST_FILE"
  fi
fi

# ------------------------- 5b. never clobber a verdict the local side pushed
# The agent's copy of results/status/handshake.json goes stale the moment the
# watcher writes its verdict back. Committing that stale copy REVERTED
# "local_state: passed" to "pending" (field incident 2026-09-16) - which made
# the watcher run the same round a second time. Rule: if the remote handshake is
# not behind ours (same round, and the local side already answered it), take the
# remote file instead of our stale one.
HANDSHAKE="results/status/handshake.json"
if [ -f "$HANDSHAKE" ] && git cat-file -e "$ORIGIN:$HANDSHAKE" 2>/dev/null; then
  PYH=""
  if [ -z "$PYH" ]; then PYH="$(command -v python3 || command -v python || true)"; fi
  if [ -n "$PYH" ] && $PYH -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    KEEP=$($PYH - "$HANDSHAKE" "$ORIGIN:$HANDSHAKE" "$PYH" <<'PYHS'
import json, subprocess, sys
loc, rev, py = sys.argv[1], sys.argv[2], sys.argv[3]
def load(a, is_rev):
    txt = subprocess.run(['git','show',a],capture_output=True,text=True).stdout if is_rev else open(a,encoding='utf-8').read()
    try: return json.loads(txt)
    except Exception: return {}
L, R = load(loc, False), load(rev, True)
try: lr, rr = int(L.get('round') or 0), int(R.get('round') or 0)
except Exception: lr = rr = 0
# the local side has answered (or will: remote_updated newer) -> prefer remote
if R and (rr > lr or (rr == lr and R.get('local_updated') and (L.get('local_state') or 'pending') == 'pending')):
    print('remote')
else:
    print('local')
PYHS
)
    if [ "$KEEP" = "remote" ]; then
      git checkout "$ORIGIN" -- "$HANDSHAKE" 2>/dev/null && \
        echo "== handshake: took the remote copy (local side already answered - would have reverted it)"
    fi
  fi
fi

# --------------------------------------------------------- 6. commit + push
git add -A
if [ -z "$(git status --porcelain)" ]; then
  echo "== nothing new to commit"
else
  if [ -z "${MSG:-}" ]; then
    if [ "$HAD_CHANGES" = "0" ] && [ -n "$USER_COMMITS" ]; then
      MSG="sync: 回执 - pulled $(printf '%s' "$USER_COMMITS" | grep -c .) local commit(s)"
    else
      MSG="sync: agent update $(date '+%Y-%m-%d %H:%M')"
    fi
  fi
  git -c user.name="Arena Agent" -c user.email="agent@arena.ai" commit -q -m "$MSG"
  echo "== committed: $(git log -1 --oneline)"
fi

if ! git push "$REMOTE" "$BRANCH" 2>&1 | tail -3; then
  echo "[ERROR] push failed" >&2
  status_report
  exit 3
fi

echo ""
echo "== done: $(git log -1 --oneline --decorate)"
echo "== user side: .\\sync.ps1   (receipt: ${RECEIPT:-none}; deliverables: .\\download.ps1 -Set final)"
