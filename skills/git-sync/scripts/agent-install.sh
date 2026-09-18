#!/usr/bin/env bash
# agent-install.sh - install (or upgrade) the git-sync skill in ANY repository.
# This is the one-command installer a brand-new Arena session can run.
#
# One-liner for a brand-new Arena session (run inside the target repo; git
# clone works in the sandboxes where raw.githubusercontent.com is blocked):
#   git clone --quiet --depth 1 -b arena/01a0ae7a-new \
#        https://github.com/shaohuawen03-cyber/new.git /tmp/git-sync-src \
#     && bash /tmp/git-sync-src/skills/git-sync/scripts/agent-install.sh \
#            --branch <working-branch>
# v2.9.2: the skill's home is arena/01a0ae7a-new on shaohuawen03-cyber/new
# ("future sessions install from THIS branch"); the legacy
# mqgg5630-cyber/git-pull-arena stays as a fallback candidate.
#
# From a local checkout of the skill source repo:
#   bash agent-install.sh [--repo /path/to/target] [--branch arena/xxx] \
#        [--source <git-url | local-path>] [--source-branch <b>] [--gha]
#
# What it does:
#   1. locate the target repo (cwd or --repo); refuse to install on main/master
#   2. fetch the skill folder from the source: --source (git URL or local path)
#      or the canonical repo below (tries main first, then the arena branch)
#   3. copy skills/git-sync/ into the repo; an EXISTING sync.config.json is
#      kept (only branch/remote and missing keys are updated) - an upgrade
#      never throws away your download_sets / upload_map / gate
#   4. copy the 8 user-side .ps1 scripts to the repo root
#   5. create code/check_all.sh (the ASCII + config gate) when missing
#   6. --gha also installs .github/workflows/gate.yml (run the gate on push)
#   7. nothing is committed - finish with agent-sync.sh
#
# Exit codes: 0 ok, 1 usage/guard, 2 source problem, 3 git/config problem.

set -u -o pipefail

# Candidate sources, canonical first. Each entry is "repo|branch": the
# installer probes them all and installs the NEWEST skill it finds (it never
# downgrades). v2.9.2 moved the skill home to the branch the user pointed at;
# the legacy repo stays last so an older machine still gets a working skill.
SOURCE_CANDIDATES=(
  "https://github.com/shaohuawen03-cyber/new.git|arena/01a0ae7a-new"
  "https://github.com/shaohuawen03-cyber/new.git|main"
  "https://github.com/mqgg5630-cyber/git-pull-arena.git|arena/01a0a98d-git-pull-arena"
  "https://github.com/mqgg5630-cyber/git-pull-arena.git|arena/01a0a821-git-pull-arena"
  "https://github.com/mqgg5630-cyber/git-pull-arena.git|main"
)
# kept for the usage text and for callers that still reference them
DEFAULT_SOURCE_REPO="https://github.com/shaohuawen03-cyber/new.git"
DEFAULT_SOURCE_BRANCHES=("arena/01a0ae7a-new" "main")

REPO=""; BRANCH=""; SOURCE=""; SOURCE_BRANCH=""; GHA=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --branch)        BRANCH="$2"; shift 2 ;;
    --source)        SOURCE="$2"; shift 2 ;;
    --source-branch) SOURCE_BRANCH="$2"; shift 2 ;;
    --gha)           GHA=1; shift ;;
    --force)         FORCE=1; shift ;;
    -h|--help)       sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# version compare: ver_ge A B  ->  true when A >= B (dotted numbers, "2.10" > "2.9")
ver_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}
read_ver() {  # $1 = skill dir -> prints its VERSION (or 0)
  if [ -f "$1/VERSION" ]; then tr -d '[:space:]' < "$1/VERSION"; else echo 0; fi
}

# ---------------------------------------------------------------- 1. target
[ -z "$REPO" ] && REPO="$PWD"
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "[ERROR] cannot enter repo: $REPO" >&2; exit 3; }
[ -d "$REPO/.git" ] || { echo "[ERROR] not a git repository: $REPO" >&2; exit 3; }
cd "$REPO"
[ -z "$BRANCH" ] && BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$BRANCH" in
  HEAD|'')
    echo "[ERROR] cannot detect the working branch (empty repo?) - pass --branch <name>" >&2
    exit 1 ;;
esac
case "$BRANCH" in
  main|master)
    echo "[REFUSED] target branch is $BRANCH - create/switch to a working branch first (--branch arena/...)" >&2
    exit 1 ;;
esac
REMOTE_NAME="$(git remote | head -1)"
[ -z "$REMOTE_NAME" ] && REMOTE_NAME="origin"

echo "== target : $REPO"
echo "== branch : $BRANCH  (remote: $REMOTE_NAME)"

# ---------------------------------------------------------------- 2. source
# One scratch dir for the whole run: the first branch is a shallow clone, every
# other candidate is a shallow FETCH into the same dir, so comparing versions
# across branches costs one negotiation instead of one full clone each.
WORKDIR="$(mktemp -d)"
cleanup() {
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

fetch_source() {  # $1 url  $2 branch  $3 dir -> prints the dir with that branch checked out
  local url="$1" br="$2" dir="$3"
  if [ ! -d "$dir/.git" ]; then
    git clone --quiet --depth 1 --single-branch --no-tags --branch "$br" "$url" "$dir" 2>/dev/null || return 1
  else
    git -C "$dir" fetch --quiet --depth 1 origin "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null || return 1
    git -C "$dir" checkout --quiet --force -B "probe-$br" "origin/$br" 2>/dev/null || return 1
  fi
  echo "$dir"
}

SRC=""; LOCAL_SOURCE=0
if [ -n "$SOURCE" ]; then
  if [ -d "$SOURCE/skills/git-sync" ]; then
    SRC="$SOURCE"
    LOCAL_SOURCE=1
    echo "== source: $SOURCE (local)"
  else
    if [ -z "$SOURCE_BRANCH" ]; then
      echo "[ERROR] --source <git-url> also needs --source-branch <b>" >&2
      exit 2
    fi
    SRC="$(fetch_source "$SOURCE" "$SOURCE_BRANCH")"
    [ -z "$SRC" ] && { echo "[ERROR] clone failed: $SOURCE ($SOURCE_BRANCH)" >&2; exit 2; }
    echo "== source: $SOURCE ($SOURCE_BRANCH)"
  fi
else
  # Probe every candidate and keep the NEWEST skill found ("first branch wins"
  # could pick an older release over a newer one - comparing versions is the
  # only honest ordering). Ties keep the earlier candidate, i.e. the canonical
  # source. The no-downgrade guard below still protects the installed copy.
  _idx=0; _best_ver=""; _best_dir=""; _best_repo=""; _best_branch=""
  for _pair in "${SOURCE_CANDIDATES[@]}"; do
    _repo="${_pair%%|*}"; _branch="${_pair##*|}"
    _idx=$((_idx + 1))
    TRY="$(fetch_source "$_repo" "$_branch" "$WORKDIR/$_idx")" || TRY=""
    if [ -z "$TRY" ] || [ ! -d "$TRY/skills/git-sync" ]; then
      echo "== no skill on $_branch @ $_repo - trying the next candidate"
      continue
    fi
    _v="$(read_ver "$TRY/skills/git-sync")"
    echo "== candidate: $_repo ($_branch) - skill v$_v"
    if [ -z "$_best_dir" ] || ! ver_ge "$_best_ver" "$_v"; then
      _best_ver="$_v"; _best_dir="$TRY"; _best_repo="$_repo"; _best_branch="$_branch"
    fi
  done
  if [ -n "$_best_dir" ]; then
    SRC="$_best_dir"; SRC_BRANCH_USED="$_best_branch"
    echo "== source: $_best_repo ($_best_branch) - newest skill v$_best_ver"
  fi
fi

[ -n "$SRC" ] && [ -d "$SRC/skills/git-sync" ] || {
  echo "[ERROR] could not fetch the skill from any source (offline?)" >&2; exit 2; }

# ---------------------------------------------------------------- 3. install
# keep the target's existing config across the upgrade
# (some repos keep the config at the repo ROOT - a minimal install without
#  the skills folder, as seen on AgentArena - so check both locations)
OLD_CFG_B64=""
if [ -f "$REPO/skills/git-sync/sync.config.json" ]; then
  OLD_CFG_B64="$(base64 -w0 "$REPO/skills/git-sync/sync.config.json" 2>/dev/null || true)"
elif [ -f "$REPO/sync.config.json" ]; then
  OLD_CFG_B64="$(base64 -w0 "$REPO/sync.config.json" 2>/dev/null || true)"
fi

mkdir -p "$REPO/skills"
# ------------------------------------------------- never install an older skill
# The old behaviour wiped skills/git-sync and copied whatever the source had,
# so following the documented one-liner on a repo that already carried v2.7.x
# silently downgraded it to the v2.6.7 on main and deleted the newer files.
NEW_VER="$(read_ver "$SRC/skills/git-sync")"
if [ -f "$REPO/skills/git-sync/VERSION" ]; then
  OLD_VER="$(read_ver "$REPO/skills/git-sync")"
  if [ "$FORCE" != "1" ] && ! ver_ge "$NEW_VER" "$OLD_VER"; then
    echo "[REFUSED] refusing to downgrade skills/git-sync: installed v$OLD_VER, source has v$NEW_VER" >&2
    echo "          the copy step deletes the skill folder, so a downgrade loses files." >&2
    echo "          point --source/--source-branch at the newer skill, or pass --force." >&2
    exit 2
  fi
  echo "== upgrade: v$OLD_VER -> v$NEW_VER"
fi
rm -rf "$REPO/skills/git-sync"
cp -r "$SRC/skills/git-sync" "$REPO/skills/git-sync"
VER=""
[ -f "$SRC/skills/git-sync/VERSION" ] && VER="$(tr -d '[:space:]' < "$SRC/skills/git-sync/VERSION")"
echo "OK: skills/git-sync installed${VER:+ (v$VER)}"

CFG="$REPO/skills/git-sync/sync.config.json"
if ! python3 - "$CFG" "$BRANCH" "$REMOTE_NAME" "$OLD_CFG_B64" <<'PY'
import base64, json, sys

cfg_path, branch, remote, old_b64 = sys.argv[1:5]
if old_b64:
    cfg = json.loads(base64.b64decode(old_b64).decode('utf-8'))
    mode = 'updated (existing sets / map / gate kept)'
else:
    cfg = {}
    mode = 'created (defaults)'

cfg['branch'] = branch
cfg['remote'] = remote
cfg.setdefault('download_dir', '')
cfg.setdefault('download_sets', {'final': ['deliverable']})
cfg.setdefault('upload_map', {
    '.docx': 'sources', '.doc': 'sources', '.pptx': 'sources', '.ppt': 'sources',
    '.pdf': 'sources', '.md': 'sources', '.txt': 'sources', '.zip': 'sources',
    '.py': 'code', '.ipynb': 'code',
    '.xlsx': 'results', '.xls': 'results', '.csv': 'results'})
cfg.setdefault('gate', 'bash code/check_all.sh')
cfg.setdefault('receipt', 'results/sync/last_sync.md')
cfg.setdefault('receipt_history', 'results/sync/history')
cfg.setdefault('hardware_dir', 'results/hardware')
cfg.setdefault('handshake', 'results/status/handshake.json')
cfg.setdefault('check_cmd', 'powershell -NoProfile -ExecutionPolicy Bypass -File code/local_check.ps1')
cfg.setdefault('check_timeout_min', 30)
cfg.setdefault('lock_stale_min', 45)
cfg.setdefault('hands_free', True)
cfg.setdefault('auto_pull', True)
cfg.setdefault('auto_push', True)
cfg.setdefault('auto_push_prefix', 'local: auto')
cfg.setdefault('auto_push_exclude', [
    '.env', '.env.*', '**/*.pem', '**/*.key',
    '**/credentials*', '**/*secret*', '**/*token*'])
cfg.setdefault('success_criteria', 'results/status/success_criteria.json')

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
print('OK: sync.config.json ' + mode)
PY
then
  echo "[ERROR] writing sync.config.json failed (is python3 available?)" >&2
  exit 3
fi

# 3b. some repos ignore skills/ entirely (AgentArena does) - the skill would
# stay untracked and a clean clone would fail the gate. Detect and un-ignore:
# a bare 'skills/' line is rewritten as the exclude-all-but-one dance (a
# plain '!skills/git-sync/' cannot re-include under an excluded parent dir)
if git -C "$REPO" check-ignore -q "skills/git-sync/sync.config.json" 2>/dev/null; then
  if grep -qx 'skills/' "$REPO/.gitignore" 2>/dev/null; then
    sed -i 's|^skills/$|skills/*\n!skills/git-sync/|' "$REPO/.gitignore"
  else
    printf '\n# git-sync skill must be tracked (un-ignored by agent-install.sh)\n!skills/git-sync/\n' >> "$REPO/.gitignore"
  fi
  if git -C "$REPO" check-ignore -q "skills/git-sync/sync.config.json" 2>/dev/null; then
    echo "WARN: skills/git-sync is still git-ignored - fix .gitignore manually (a parent dir pattern excludes it)" >&2
  else
    echo "OK: skills/git-sync un-ignored in .gitignore (was swallowed by a skills/ rule)"
  fi
fi

# 4. the user-side scripts at the repo root
for f in sync push upload download pack doctor bootstrap pr hardware watch auth install; do
  if [ -f "$REPO/skills/git-sync/scripts/$f.ps1" ]; then
    cp "$REPO/skills/git-sync/scripts/$f.ps1" "$REPO/$f.ps1"
  fi
done
echo "OK: user-side .ps1 scripts copied to the repo root"

# 5. the gate (create only - never overwrite a repo's own checks)
if [ ! -f "$REPO/code/check_all.sh" ] && [ -f "$REPO/skills/git-sync/templates/check_all.sh" ]; then
  mkdir -p "$REPO/code"
  cp "$REPO/skills/git-sync/templates/check_all.sh" "$REPO/code/check_all.sh"
  echo "OK: code/check_all.sh created (pre-commit gate)"
fi

# 5a. the gate's .ps1 typo scanner (create only; the gate falls back to the
#     skill copy when this is missing, so older installs keep working)
if [ -f "$REPO/skills/git-sync/templates/scan_ps_var_colon.py" ] && [ ! -f "$REPO/code/scan_ps_var_colon.py" ]; then
  mkdir -p "$REPO/code"
  cp "$REPO/skills/git-sync/templates/scan_ps_var_colon.py" "$REPO/code/scan_ps_var_colon.py"
  echo "OK: code/scan_ps_var_colon.py created (gate helper: catches \$var: typos)"
fi

# 5a2. the watcher closing-line checkers (create only). local_check.ps1 section
#      2c runs code/check_loop_summary.ps1 and the gate falls back to the python
#      twin; without either, a fresh install always printed "[WARN] accept 2c:
#      code\\check_loop_summary.ps1 is missing" - seen in the round-1 log on
#      LAPTOP-R77M5D6M (2026-09-17). install.ps1 always copied them; the bash
#      installer only copied the scanner above.
for h in check_loop_summary.ps1 check_loop_summary.py; do
  if [ -f "$REPO/skills/git-sync/templates/$h" ] && [ ! -f "$REPO/code/$h" ]; then
    mkdir -p "$REPO/code"
    cp "$REPO/skills/git-sync/templates/$h" "$REPO/code/$h"
    echo "OK: code/$h created (watch.ps1 closing-line check)"
  fi
done

# 5b. the local check template for the auto-verification loop (create only)
if [ ! -f "$REPO/code/local_check.ps1" ] && [ -f "$REPO/skills/git-sync/templates/local_check.ps1" ]; then
  mkdir -p "$REPO/code"
  cp "$REPO/skills/git-sync/templates/local_check.ps1" "$REPO/code/local_check.ps1"
  echo "OK: code/local_check.ps1 created (what watch.ps1 runs - edit it per repo)"
fi

# 5c. short-prompt mapping page (arena.ai/01a0a821 -> this GitHub clone)
MAP_SRC=""
if [ -f "$SRC/01a0a821.md" ]; then
  MAP_SRC="$SRC/01a0a821.md"
elif [ -f "$REPO/skills/git-sync/templates/01a0a821.md" ]; then
  MAP_SRC="$REPO/skills/git-sync/templates/01a0a821.md"
fi
if [ -n "$MAP_SRC" ]; then
  cp "$MAP_SRC" "$REPO/01a0a821.md"
  echo "OK: 01a0a821.md (short prompt maps to GitHub clone; do not open arena.ai)"
fi

# 6. optional: the GitHub Actions workflow that runs the gate on push
#    (the push needs workflows permission - user-side installs always work)
if [ "$GHA" = "1" ] && [ -f "$REPO/skills/git-sync/templates/gate.yml" ]; then
  mkdir -p "$REPO/.github/workflows"
  cp "$REPO/skills/git-sync/templates/gate.yml" "$REPO/.github/workflows/gate.yml"
  echo "OK: .github/workflows/gate.yml installed (gate runs on every push)"
  echo "    note: pushing it needs workflows permission - if the agent token lacks"
  echo "    it, commit it from the user side (.\\push.ps1) instead"
fi

cat <<EOF

== git-sync skill installed in:
   $REPO
   branch : $BRANCH
   config : skills/git-sync/sync.config.json  (edit sets / upload_map there)

next (assistant side):
   bash skills/git-sync/scripts/agent-sync.sh "feat: install git-sync skill"

next (user side, after the branch is pushed):
   git clone -b $BRANCH <remote-url> && cd <repo>
   .\\bootstrap.ps1 -Auto      # policy + identity + branch + silent-push auth + watcher
   (or step by step: .\\bootstrap.ps1, .\\auth.ps1 -Setup, .\\watch.ps1 -Register)
EOF
