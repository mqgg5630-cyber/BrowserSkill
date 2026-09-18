#!/usr/bin/env bash
# agent-criteria.sh - evaluate results/status/success_criteria.json (or path
# from sync.config.json key "success_criteria").
#
# Usage:
#   bash skills/git-sync/scripts/agent-criteria.sh           # evaluate, print report
#   bash skills/git-sync/scripts/agent-criteria.sh --json    # machine-readable
#   bash skills/git-sync/scripts/agent-criteria.sh --path P  # override file
#
# Exit: 0 = all criteria met, 2 = not met, 1 = usage/config error, 3 = no criteria file.
#
# Schema (all keys optional):
# {
#   "description": "...",
#   "require_files": ["path", "deliverable/*.docx"],  # must exist (globs: >=1 hit)
#   "require_contains": { "path": "substring" },
#   "min_bytes": { "path": 1234 },
#   "max_bytes": { "path": 999999 },
#   "require_regex": { "path": "regex" },             # python re.search
#   "forbid_files": ["path", ...]                     # must NOT exist
# }

set -u -o pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

CFG="skills/git-sync/sync.config.json"
CRITERIA=""
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --path) CRITERIA="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$CRITERIA" ] && [ -f "$CFG" ]; then
  CRITERIA="$(python3 -c "import json;print(json.load(open('$CFG',encoding='utf-8')).get('success_criteria',''))" 2>/dev/null || true)"
fi
[ -z "$CRITERIA" ] && CRITERIA="results/status/success_criteria.json"
CRITERIA="${CRITERIA//\\//}"

if [ ! -f "$CRITERIA" ]; then
  echo "== no success_criteria file at $CRITERIA"
  exit 3
fi

python3 - "$CRITERIA" "$JSON" <<'PY'
import glob as globmod
import json, os, re, sys
path, as_json = sys.argv[1], sys.argv[2] == "1"
with open(path, encoding="utf-8-sig") as f:
    c = json.load(f)

fails = []
oks = []

def ok(msg): oks.append(msg)
def bad(msg): fails.append(msg)

def expand(p):
    p = str(p).replace("\\", "/")
    if any(ch in p for ch in "*?["):
        return [h.replace("\\", "/") for h in sorted(globmod.glob(p, recursive=True)) if os.path.isfile(h)]
    return [p]

for p in c.get("require_files") or []:
    hits = expand(p)
    if any(ch in str(p) for ch in "*?["):
        if hits:
            h = hits[0]
            ok(f"exists (glob {p}): {h} ({os.path.getsize(h)} B, {len(hits)} hit(s))")
        else:
            bad(f"MISSING file matching: {p}")
        continue
    if os.path.isfile(p):
        ok(f"exists: {p} ({os.path.getsize(p)} B)")
    else:
        bad(f"MISSING file: {p}")

for p in c.get("forbid_files") or []:
    hits = expand(p)
    if any(ch in str(p) for ch in "*?["):
        if hits:
            bad(f"FORBIDDEN still present ({p}): {hits[0]}")
        else:
            ok(f"absent (good, glob): {p}")
        continue
    if os.path.exists(p):
        bad(f"FORBIDDEN still present: {p}")
    else:
        ok(f"absent (good): {p}")

def read_text(p):
    return open(p, encoding="utf-8-sig", errors="replace").read()

for p, sub in (c.get("require_contains") or {}).items():
    hits = expand(p)
    target = hits[0] if hits else p
    if not os.path.isfile(target):
        bad(f"MISSING for contains: {p}")
        continue
    try:
        text = read_text(target)
    except Exception as e:
        bad(f"unreadable {target}: {e}")
        continue
    if str(sub) in text:
        ok(f"contains {target!r} <- {sub!r}")
    else:
        bad(f"DOES NOT contain in {target}: {sub!r}")

for p, rx in (c.get("require_regex") or {}).items():
    hits = expand(p)
    target = hits[0] if hits else p
    if not os.path.isfile(target):
        bad(f"MISSING for regex: {p}")
        continue
    text = read_text(target)
    if re.search(str(rx), text, re.M):
        ok(f"regex ok {target}: {rx}")
    else:
        bad(f"regex FAIL {target}: {rx}")

for p, n in (c.get("min_bytes") or {}).items():
    hits = expand(p)
    target = hits[0] if hits else p
    if not os.path.isfile(target):
        bad(f"MISSING for min_bytes: {p}")
        continue
    sz = os.path.getsize(target)
    if sz >= int(n):
        ok(f"size ok {target}: {sz} >= {n}")
    else:
        bad(f"TOO SMALL {target}: {sz} < {n}")

for p, n in (c.get("max_bytes") or {}).items():
    hits = expand(p)
    target = hits[0] if hits else p
    if not os.path.isfile(target):
        bad(f"MISSING for max_bytes: {p}")
        continue
    sz = os.path.getsize(target)
    if sz <= int(n):
        ok(f"size ok {target}: {sz} <= {n}")
    else:
        bad(f"TOO BIG {target}: {sz} > {n}")

report = {
    "criteria": path,
    "description": c.get("description", ""),
    "passed": len(fails) == 0,
    "ok": oks,
    "fail": fails,
}
if as_json:
    print(json.dumps(report, ensure_ascii=False, indent=2))
else:
    print(f"== success criteria: {path}")
    if report["description"]:
        print(f"   {report['description']}")
    for m in oks:
        print(f"   OK   {m}")
    for m in fails:
        print(f"   FAIL {m}")
    print(f"== result: {'PASSED' if report['passed'] else 'FAILED'}  ({len(oks)} ok / {len(fails)} fail)")

sys.exit(0 if report["passed"] else 2)
PY
