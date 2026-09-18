#!/usr/bin/env bash
# check_all.sh (template) - pre-commit gate, installed by agent-install.sh
# into code/check_all.sh when the target repo has none.
#
#   1. every .ps1 must be ASCII-only: Windows PowerShell 5.1 decodes BOM-less
#      .ps1 as ANSI/GBK, so any non-ASCII byte breaks the parser.
#      (Chinese goes into .md / .json only.)
#   2. skills/git-sync/sync.config.json must parse and point at a working
#      branch - never main/master - and that branch must be the one HEAD is on
#      (2b), otherwise the local watcher polls a branch nobody pushes to.
#   3. the .ps1 copies at the repo root must be identical to the ones in
#      skills/git-sync/scripts/ (they are the same scripts).
#   4. every .ps1 must PARSE (PowerShell's own parser, when PowerShell is on
#      PATH) - an unbalanced brace survives the ASCII check but breaks at
#      runtime, and the watcher would then fail every round silently.
#   (3b. no drive-style "$var:" typos; 3c. every watcher poll exit must record
#    a closing summary line - see code/check_loop_summary.py)
#
# Exit 0 = ok, 1 = failed.

set -u -o pipefail
cd "$(dirname "$0")/.."
fail=0

# Resolve a WORKING python once. Windows machines routinely have a
# "python"/"python3" that is only the Microsoft Store stub: it answers
# `command -v` and then exits non-zero, which made the gate SKIP its python
# checks on the local machine (field report: "python3 is not a working python"
# on LAPTOP-R77M5D6M, which does have a conda python). So prove each candidate
# before trusting it, and try the py launcher as well.
PY=""
for cand in python3 python "py -3"; do
    if $cand -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        PY="$cand"
        break
    fi
done

# ---------------------------------------------------------------- 1. ps1
while IFS= read -r -d '' f; do
    if LC_ALL=C grep -qn '[^[:print:][:space:]]' "$f"; then
        echo "[FAIL] non-ASCII bytes in $f  (keep .ps1 ASCII-only; put Chinese in .md/.json)"
        fail=1
    fi
done < <(find . -name '*.ps1' -not -path './.git/*' -print0)
if [ "$fail" -eq 0 ]; then
    echo "OK: all .ps1 files are ASCII-only"
fi

# -------------------------------------------------------------- 2. config
CFG='skills/git-sync/sync.config.json'
cfgDone=0
if [ -n "$PY" ]; then
    # a python on PATH is not necessarily a WORKING python (the Windows Store
    # stub answers `command -v` and then fails), so prove it before trusting it
    if $PY -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        cfgOut=$($PY - <<'PYCHECK' 2>&1
import json
cfg = json.load(open('skills/git-sync/sync.config.json', encoding='utf-8'))
branch = cfg.get('branch', '')
assert branch and branch not in ('main', 'master'), 'bad branch: %r' % branch
assert cfg.get('remote'), 'remote missing'
print('OK: sync.config.json branch=%s' % branch)
PYCHECK
)
        cfgCode=$?
        if [ $cfgCode -eq 0 ]; then
            echo "$cfgOut"
            cfgDone=1
        else
            echo "NOTE: python could not validate the config (exit $cfgCode) - trying plain text"
            echo "$cfgOut" | tail -2 | sed 's/^/      /'
        fi
    else
        echo "NOTE: $PY is not a working python - trying plain text"
    fi
fi
if [ $cfgDone -eq 0 ]; then
    # portable fallback: read the two keys with sed, so a broken/absent python
    # cannot fail a perfectly valid config (field report 2026-09-16)
    CFGBR=$(sed -n 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)
    CFGRM=$(sed -n 's/.*"remote"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)
    if [ -n "$CFGBR" ] && [ "$CFGBR" != "main" ] && [ "$CFGBR" != "master" ] && [ -n "$CFGRM" ]; then
        echo "OK: sync.config.json branch=$CFGBR remote=$CFGRM (checked without python)"
    elif [ ! -f "$CFG" ]; then
        echo "[FAIL] $CFG is missing"
        fail=1
    else
        echo "[FAIL] $CFG has no usable branch/remote (branch='$CFGBR' remote='$CFGRM')"
        fail=1
    fi
fi

# ------------------------------------------- 2b. config branch == HEAD branch
# The single failure that silently kills a round (field report 2026-09-16):
# a new session inherits sync.config.json from the PREVIOUS one, so the agent
# pushes to branch A while the local watcher polls branch B. Nothing errors -
# the request just sits in `pending` forever. agent-sync.sh refuses to run in
# that state, so catch it here too, before any push.
HEADBR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
CFGBRANCH="$(sed -n 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)"
if [ -z "$HEADBR" ]; then
    echo "NOTE: not a git checkout - branch match not checked"
elif [ -z "$CFGBRANCH" ]; then
    echo "NOTE: $CFG has no branch key - branch match not checked"
elif [ "$CFGBRANCH" = "$HEADBR" ]; then
    echo "OK: sync.config.json branch matches HEAD ($HEADBR)"
else
    echo "[FAIL] sync.config.json branch=$CFGBRANCH but HEAD is $HEADBR"
    echo "       the local watcher polls the config branch, so it would never see"
    echo "       this session's requests. Point the config at HEAD (or re-run"
    echo "       skills/git-sync/scripts/agent-install.sh) before pushing."
    fail=1
fi

# ------------------------------------------------- 3. root vs skill scripts
drift=0
for f in sync push upload download pack doctor bootstrap pr hardware watch auth install; do
    if [ -f "skills/git-sync/scripts/$f.ps1" ]; then
        if [ ! -f "$f.ps1" ]; then
            echo "[FAIL] $f.ps1 is missing at the repo root (the skill ships it)"
            drift=1
        elif ! cmp -s "$f.ps1" "skills/git-sync/scripts/$f.ps1"; then
            echo "[FAIL] $f.ps1 differs from skills/git-sync/scripts/$f.ps1 - copy it over"
            drift=1
        fi
    fi
done
if [ "$drift" = "0" ]; then
    echo "OK: root scripts identical to skills/git-sync/scripts"
else
    fail=1
fi

# --------------------------------- 3b. "$var:" inside a string = dead script
# "$round: text" is read as a DRIVE-qualified variable name -> ParserError ->
# and PowerShell parses a whole file before running it, so ONE of these makes
# the script do nothing at all (field incident 2026-09-15: watch.ps1 never ran,
# every scheduled task stayed silently dead). Scopes/drives ($env:, $script:)
# are fine; anything else must be written as ${var}:
SCANNER=""
for cand in code/scan_ps_var_colon.py skills/git-sync/templates/scan_ps_var_colon.py; do
    if [ -f "$cand" ]; then SCANNER="$cand"; break; fi
done
if [ -z "$SCANNER" ]; then
    echo "SKIP: \$var: typo scanner not present in this repo"
elif [ -z "$PY" ]; then
    echo "SKIP: no python on PATH - \$var: typo scan skipped"
elif ! $PY -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    echo "SKIP: $PY is not a working python - \$var: typo scan skipped here"
    echo "      (it still runs in the agent sandbox before every push)"
elif $PY "$SCANNER"; then
    echo "OK: no drive-style variable typos (\$var:)"
else
    fail=1
fi

# ------------------------ 3c. does every poll exit print a closing line?
# A poll that returns without recording a closing line leaves the watcher
# console sitting on whatever the previous round printed, which reads as
# "stuck" (field question 2026-09-16). watch.ps1 v2.6.8 therefore sets
# $script:PollSummary on EVERY exit of Invoke-PollRound / Invoke-PollOnce and
# the loop / manual poll print it. This check keeps that rule from rotting the
# next time somebody adds a `return`.
LOOPCHK=""
for cand in code/check_loop_summary.py skills/git-sync/templates/check_loop_summary.py; do
    if [ -f "$cand" ]; then LOOPCHK="$cand"; break; fi
done
WATCHSRC=""
for cand in watch.ps1 skills/git-sync/scripts/watch.ps1; do
    if [ -f "$cand" ]; then WATCHSRC="$cand"; break; fi
done
if [ -z "$LOOPCHK" ]; then
    echo "SKIP: check_loop_summary.py not present in this repo"
elif [ -z "$WATCHSRC" ]; then
    echo "SKIP: no watch.ps1 to check for closing lines"
elif [ -z "$PY" ]; then
    echo "SKIP: no python on PATH - watcher closing-line check skipped"
elif ! $PY -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    echo "SKIP: $PY is not a working python - watcher closing-line check skipped here"
    echo "      (it still runs in the agent sandbox before every push)"
else
    loopOut=$($PY "$LOOPCHK" "$WATCHSRC" 2>&1)
    loopCode=$?
    echo "$loopOut"
    if [ $loopCode -ne 0 ]; then
        fail=1
    fi
fi

# ------------------------------------------------- 4. does every .ps1 parse?
# The ASCII check above only proves the bytes are safe; it says nothing about
# the syntax. An unbalanced brace or quote would only show up at runtime - and
# in the watcher that means every verification round fails silently. Use
# PowerShell's own parser when one is on PATH (git-bash on Windows finds
# powershell.exe; Linux/macOS may have pwsh). Skipped loudly when absent.
SH_EXE=""
if command -v pwsh >/dev/null 2>&1; then SH_EXE="pwsh"
elif command -v powershell >/dev/null 2>&1; then SH_EXE="powershell"
elif command -v powershell.exe >/dev/null 2>&1; then SH_EXE="powershell.exe"
fi

if [ -z "$SH_EXE" ]; then
    echo "SKIP: no PowerShell on PATH - .ps1 syntax not parse-checked here"
else
    PS_PARSE='$bad = 0
Get-ChildItem -Path . -Recurse -Filter *.ps1 | ForEach-Object {
    if ($_.FullName -like "*\.git\*") { return }
    $t = $null
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) {
        Write-Output ("[FAIL] PowerShell parse error in " + $_.FullName)
        foreach ($x in $e) { Write-Output ("       " + $x.Message) }
        $bad = 1
    }
}
if ($bad -eq 0) { Write-Output "OK: every .ps1 parses" }
exit $bad'
    if "$SH_EXE" -NoProfile -NonInteractive -Command "$PS_PARSE"; then
        :
    else
        echo "[FAIL] at least one .ps1 does not parse - fix it before committing"
        fail=1
    fi
fi

exit $fail
