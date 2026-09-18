#!/usr/bin/env bash
# agent-wait.sh - request a local check AND wait for the verdict, so the whole
# verify loop closes inside ONE conversation turn (no per-round user input).
#
# Usage:
#     bash skills/git-sync/scripts/agent-wait.sh                          # wait for the pending request
#     bash skills/git-sync/scripts/agent-wait.sh --request "verify X"     # new round, then wait
#     bash skills/git-sync/scripts/agent-wait.sh --request "X" --timeout auto --interval 15
#     bash skills/git-sync/scripts/agent-wait.sh --request "X" --auto-accept
#                                                         # passed -> accept automatically:
#                                                         # "work -> verify -> close" in one command
#
# Flow: [--request] -> agent-check.sh --request -> poll the remote handshake
# every --interval seconds until the local watcher pushes passed/failed (or
# arena_state=accepted). Returns THE MOMENT a verdict arrives - a 20s check
# does not sit until the cap. --timeout is only the maximum:
#     auto (default) = check_timeout_min*60 + 180  (config; floor 240, cap 7200
#                      unless wait_timeout_sec is set in sync.config.json)
#     N              = wait at most N seconds
#     0              = same as auto
#
# Exit codes (same as agent-check.sh --read):
#     0 passed / accepted      2 failed      3 still pending / timeout

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$REPO_ROOT"

CFG="skills/git-sync/sync.config.json"
BRANCH=""; REMOTE="origin"; HANDSHAKE="results/status/handshake.json"
if [ -f "$CFG" ]; then
  BRANCH="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('branch',''))" 2>/dev/null || true)"
  REMOTE="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('remote','origin'))" 2>/dev/null || true)"
  HANDSHAKE="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('handshake','results/status/handshake.json'))" 2>/dev/null || true)"
fi
[ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD)"
HS_NORM="${HANDSHAKE//\\//}"
ORIGIN="$REMOTE/$BRANCH"

NOTE=""; DO_REQUEST=0; TIMEOUT=auto; INTERVAL=15; AUTO_ACCEPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --request) DO_REQUEST=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --auto-accept) AUTO_ACCEPT=1; shift ;;
    *) NOTE="$1"; shift ;;
  esac
done

resolve_timeout() {
  # print seconds
  local raw="$1"
  if [ "$raw" = "auto" ] || [ "$raw" = "0" ] || [ -z "$raw" ]; then
    python3 - "$CFG" <<'PY'
import json, os, sys
cfg_path = sys.argv[1]
ct, explicit = 30, None
if os.path.isfile(cfg_path):
    try:
        c = json.load(open(cfg_path, encoding="utf-8"))
        ct = int(c.get("check_timeout_min") or 30)
        if c.get("wait_timeout_sec") not in (None, "", 0, "0", "auto"):
            explicit = int(c.get("wait_timeout_sec"))
    except Exception:
        pass
if explicit is not None:
    print(max(60, explicit))
else:
    # check duration + 3 min for watcher poll (default 2 min) + fetch slack
    n = ct * 60 + 180
    print(min(7200, max(240, n)))
PY
  else
    echo "$raw"
  fi
}

TIMEOUT="$(resolve_timeout "$TIMEOUT")"
INTERVAL="$(python3 -c "print(max(5,int('${INTERVAL}' or 15)))" 2>/dev/null || echo 15)"

# optional: open a new round first
if [ "$DO_REQUEST" = 1 ]; then
  bash "$HERE/agent-check.sh" --request "$NOTE" || exit 1
else
  git config "remote.$REMOTE.fetch" "+refs/heads/*:refs/remotes/$REMOTE/*"
  git fetch "$REMOTE" --quiet || { echo "[ERROR] fetch failed" >&2; exit 1; }
  if ! git show "$ORIGIN:$HS_NORM" >/dev/null 2>&1; then
    echo "[ERROR] no handshake yet - start a round with: agent-wait.sh --request \"note\"" >&2
    exit 1
  fi
fi

echo "== waiting for the local watcher (polling every ${INTERVAL}s, max ${TIMEOUT}s; returns as soon as a verdict arrives) ..."
read_hs() { git show "$ORIGIN:$HS_NORM" 2>/dev/null; }
hs_key() { printf '%s' "$(read_hs)" | python3 -c "import json,sys;d=json.loads(sys.stdin.buffer.read().decode('utf-8-sig'));print(d.get('$1',''))" 2>/dev/null; }
tip_sha() { git ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null | cut -f1; }
state="$(hs_key local_state)"
start=$SECONDS
# Round 21 closed in 47s of which most was polling latency: a fixed 15s sleep
# plus a FULL `git fetch` every tick. So (a) poll fast for the first two minutes
# - that is when a verdict normally lands - then relax, and (b) only fetch when
# ls-remote says the branch tip actually moved.
last_tip="$(tip_sha)"
while [ "$state" = "pending" ] || [ -z "$state" ]; do
  slept=$((SECONDS - start))
  remain=$((TIMEOUT - slept))
  if [ "$remain" -le 0 ]; then
    break
  fi
  printf '  [%3ds/%ds] still pending ...\r' "$slept" "$TIMEOUT"
  if [ "$slept" -lt 120 ]; then slp=5; else slp=$INTERVAL; fi
  if [ "$slp" -gt "$remain" ]; then slp=$remain; fi
  sleep "$slp"
  tip="$(tip_sha)"
  if [ "$tip" != "$last_tip" ]; then
    git fetch "$REMOTE" --quiet || true
    last_tip="$tip"
    state="$(hs_key local_state)"
    astate="$(hs_key arena_state)"
    [ "$astate" = "accepted" ] && state="passed"
  fi
done
echo ""

elapsed=$((SECONDS - start))
case "$state" in
  passed) echo "== verdict: PASSED (after ${elapsed}s, cap was ${TIMEOUT}s)" ;;
  failed) echo "== verdict: FAILED (after ${elapsed}s, cap was ${TIMEOUT}s)" ;;
  *)      echo "== verdict: still pending after ${TIMEOUT}s (watcher offline? check .\\watch.ps1 and Get-ScheduledTask git-sync-watch-*)" ;;
esac

# --auto-accept: close the loop right away when the local checks passed
if [ "$state" = "passed" ] && [ "$AUTO_ACCEPT" = 1 ]; then
  echo "== auto-accept: local checks passed - closing the loop"
  bash "$HERE/agent-check.sh" --accept | head -2
fi

# full report + exit code from the reader (0 passed / 2 failed / 3 pending)
exec bash "$HERE/agent-check.sh" --read
