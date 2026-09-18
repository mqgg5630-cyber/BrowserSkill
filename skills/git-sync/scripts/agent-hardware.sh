#!/usr/bin/env bash
# agent-hardware.sh - read the local machine report the user uploaded with
# hardware.ps1 (results/hardware/latest.md + latest.json by default), so the
# agent knows the hardware and python envs it is working with.
#
# Usage:
#     bash skills/git-sync/scripts/agent-hardware.sh          # print the report
#     bash skills/git-sync/scripts/agent-hardware.sh --json   # raw json
#
# Warns when the report is older than 30 days (re-run .\hardware.ps1 -Deep).
# Exit codes: 0 ok, 1 no report yet.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

CFG="skills/git-sync/sync.config.json"
HW_DIR="results/hardware"
if [ -f "$CFG" ]; then
  HW_DIR="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('hardware_dir','results/hardware'))" 2>/dev/null || echo 'results/hardware')"
fi

MD="$HW_DIR/latest.md"
JS="$HW_DIR/latest.json"
if [ ! -f "$MD" ] && [ ! -f "$JS" ]; then
  echo "[ERROR] no hardware report yet ($MD)." >&2
  echo "        Ask the user to run on their machine:  .\\hardware.ps1 -Deep" >&2
  exit 1
fi

if [ "${1:-}" = "--json" ]; then
  cat "$JS" 2>/dev/null
  exit 0
fi

# staleness check from the "generated" field of the json
if [ -f "$JS" ]; then
  python3 - "$JS" <<'PY'
import json, sys, datetime
try:
    gen = json.load(open(sys.argv[1], encoding='utf-8-sig')).get('generated', '')
    dt = datetime.datetime.strptime(gen, '%Y-%m-%d %H:%M:%S')
    age = (datetime.datetime.now() - dt).days
    if age > 30:
        print('[WARN] the report is %d days old - ask the user to re-run .\\hardware.ps1 -Deep' % age)
except Exception:
    pass
PY
fi

echo "== hardware report ($HW_DIR/latest.md):"
if [ -f "$MD" ]; then
  cat "$MD"
else
  python3 -c "import json;d=json.load(open('$JS',encoding='utf-8-sig'));print(json.dumps(d,indent=2,ensure_ascii=False))"
fi
