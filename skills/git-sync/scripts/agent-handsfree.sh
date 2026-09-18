#!/usr/bin/env bash
# agent-handsfree.sh - one command for the agent to finish a round hands-free.
#
# Typical flow after the agent finishes work:
#   bash skills/git-sync/scripts/agent-handsfree.sh \
#        --sync "feat: ..." \
#        --request "verify deliverables + local roundtrip" \
#        --timeout auto
#
# What it does:
#   1) (optional) agent-sync.sh "$MSG"           # push agent work
#   2) agent-check.sh --request "$NOTE"         # ask local watcher to verify
#   3) agent-wait.sh (poll until local verdict) # local auto_pull/auto_push + check
#   4) agent-criteria.sh                        # evaluate success_criteria.json
#   5) if check PASSED AND criteria PASSED -> agent-check.sh --accept and exit 0
#      if check FAILED or criteria FAILED  -> exit 2 (agent should fix & re-run)
#      if timeout                          -> exit 3
#
# Flags:
#   --sync "msg"       run agent-sync.sh with this message first
#   --request "note"   handshake note (default: "hands-free verify")
#   --timeout N|auto   max seconds to wait (default auto = check_timeout_min*60+180;
#                       returns the moment the watcher pushes a verdict)
#   --interval N       poll interval seconds (default 15)
#   --no-request       skip --request (wait for an already-pending round)
#   --no-criteria      skip success_criteria evaluation (accept on check alone)
#   --dry-run          print the plan, do nothing
#
# Exit: 0 accepted, 2 failed, 3 timeout/pending, 1 usage.

set -u -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$REPO_ROOT"

SYNC_MSG=""
NOTE="hands-free verify"
TIMEOUT=auto
INTERVAL=15
DO_REQUEST=1
DO_CRITERIA=1
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --sync) SYNC_MSG="$2"; shift 2 ;;
    --request) NOTE="$2"; DO_REQUEST=1; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --no-request) DO_REQUEST=0; shift ;;
    --no-criteria) DO_CRITERIA=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "== agent-handsfree"
echo "   repo     : $REPO_ROOT"
echo "   sync     : ${SYNC_MSG:-'(skip)'}"
echo "   request  : $([ "$DO_REQUEST" = 1 ] && echo "$NOTE" || echo '(skip)')"
echo "   criteria : $([ "$DO_CRITERIA" = 1 ] && echo on || echo off)"
echo "   wait     : timeout=${TIMEOUT} interval=${INTERVAL}s"

if [ "$DRY" = 1 ]; then
  echo "== dry-run: stop here"
  exit 0
fi

if [ -n "$SYNC_MSG" ]; then
  echo "== step 1: agent-sync"
  bash "$HERE/agent-sync.sh" "$SYNC_MSG" || exit $?
fi

WAIT_ARGS=(--timeout "$TIMEOUT" --interval "$INTERVAL")
if [ "$DO_REQUEST" = 1 ]; then
  WAIT_ARGS=(--request "$NOTE" "${WAIT_ARGS[@]}")
fi

echo "== step 2/3: wait for local watcher"
set +e
bash "$HERE/agent-wait.sh" "${WAIT_ARGS[@]}"
WAIT_RC=$?
set -e
echo "== wait exit: $WAIT_RC"

if [ "$WAIT_RC" -eq 3 ]; then
  echo "== TIMEOUT/PENDING - is the local watcher running? (.\\watch.ps1 -Status)"
  exit 3
fi
if [ "$WAIT_RC" -eq 2 ]; then
  echo "== local check FAILED - see results/status/check_r*_*.txt"
  # still show criteria so the agent knows what is missing
  if [ "$DO_CRITERIA" = 1 ]; then
    bash "$HERE/agent-criteria.sh" || true
  fi
  exit 2
fi
if [ "$WAIT_RC" -ne 0 ]; then
  echo "== unexpected wait rc $WAIT_RC"
  exit "$WAIT_RC"
fi

# WAIT_RC == 0 : local check passed
if [ "$DO_CRITERIA" = 1 ]; then
  echo "== step 4: success criteria"
  set +e
  bash "$HERE/agent-criteria.sh"
  CR=$?
  set -e
  if [ "$CR" -eq 3 ]; then
    echo "== no criteria file - accepting on local check alone"
  elif [ "$CR" -ne 0 ]; then
    echo "== criteria FAILED - not accepting; agent should fix and re-run"
    exit 2
  fi
fi

echo "== step 5: accept (close the loop)"
bash "$HERE/agent-check.sh" --accept "hands-free: criteria met" || exit $?
echo "== HANDS-FREE DONE: local check passed + criteria met + accepted"
exit 0
