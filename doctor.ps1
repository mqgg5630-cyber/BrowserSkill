# doctor.ps1 - one-shot health check (and optional auto-fix) for the local
# <-> Arena sync setup.
#
# Usage (inside the repo folder):
#     .\doctor.ps1             # report only
#     .\doctor.ps1 -Fix        # rebuild the fetch refspec, stash stray changes,
#                              # switch back to the configured branch and pull
#
# Prints: PowerShell / git versions, repo path, execution policy, branch vs the
# branch recorded in sync.config.json, remote URL, ahead/behind, uncommitted
# files, stash entries, LFS / big-file status and the last three commits.
# Run this first whenever "something does not sync".
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [string]$Config = '',
    [switch]$Fix
)

$ErrorActionPreference = 'Continue'

# repo root = walk up from this script until .git appears, so the script also
# works when run straight from skills\git-sync\scripts\
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    $up = Split-Path -Parent $repo
    if (-not $up -or $up -eq $repo) { break }
    $repo = $up
}
Set-Location -LiteralPath $repo

function Line($label, $value, $color = 'Gray') {
    Write-Host ("{0,-14} {1}" -f $label, $value) -ForegroundColor $color
}

Write-Host "== environment" -ForegroundColor Cyan
Line 'PowerShell' $PSVersionTable.PSVersion.ToString()
Line 'git' ((git --version) 2>&1)
try { Line 'policy' (Get-ExecutionPolicy -Scope CurrentUser) } catch { Line 'policy' '(unknown)' 'Yellow' }
Line 'repo' $repo

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    Write-Host "[ERROR] not a git repository - run this from the cloned folder" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------- config
# resolution order: -Config <path> > profile file (sync.config.<PROFILE>.json,
# PROFILE from $env:GIT_SYNC_PROFILE) > skills\git-sync\sync.config.json >
# next to this script
if ($Config -and -not (Test-Path -LiteralPath $Config)) {
    Write-Host "[ERROR] config not found: $Config" -ForegroundColor Red
    exit 1
}
$cfgPath = @()
if ($Config) { $cfgPath += $Config }
if ($env:GIT_SYNC_PROFILE) {
    $prof = 'sync.config.' + $env:GIT_SYNC_PROFILE + '.json'
    $cfgPath += @(
        (Join-Path $repo ('skills\git-sync\' + $prof)),
        (Join-Path $repo $prof),
        (Join-Path $PSScriptRoot $prof)
    )
}
$cfgPath += @(
    (Join-Path $repo 'skills\git-sync\sync.config.json'),
    (Join-Path $PSScriptRoot 'sync.config.json')
)
$cfgPath = $cfgPath | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$wantBranch = ''
$remoteName = 'origin'
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $wantBranch = [string]$cfg.branch
    if ($cfg.remote) { $remoteName = [string]$cfg.remote }
    Line 'config' $cfgPath
} else {
    Line 'config' '(missing - using the branch from git)' 'Yellow'
}

$verFile = Join-Path $repo 'skills\git-sync\VERSION'
if (Test-Path -LiteralPath $verFile) {
    Line 'skill' ("v" + (Get-Content -LiteralPath $verFile -Raw).Trim())
}

Write-Host ""
Write-Host "== git state" -ForegroundColor Cyan
git fetch $remoteName --quiet 2>$null

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
Line 'branch' $branch
if ($wantBranch -and $branch -ne $wantBranch) {
    Line 'expected' ("$wantBranch   <-- run .\sync.ps1 (or .\doctor.ps1 -Fix)") 'Yellow'
}
Line 'remote' ((git remote get-url $remoteName) 2>&1)

# compare HEAD with the remote-tracking branch (origin/<branch>), not the
# local branch tip - comparing with the local tip made "behind" always 0
$upstream = "$remoteName/$wantBranch"
$ahead  = (git rev-list --count "$upstream..HEAD" 2>$null)
$behind = (git rev-list --count "HEAD..$upstream" 2>$null)
if ($wantBranch) {
    if ($ahead -and $ahead -ne '0') { Line 'ahead' "$ahead local commit(s) not on the remote" 'Yellow' }
    if ($behind -and $behind -ne '0') { Line 'behind' "$behind commit(s) on the remote - run .\sync.ps1" 'Yellow' }
    if ((-not $ahead -or $ahead -eq '0') -and (-not $behind -or $behind -eq '0')) { Line 'sync' 'in step with the remote' 'Green' }
}

$dirty = @(git status --porcelain)
Line 'uncommitted' ("$($dirty.Count) file(s)")
if ($dirty.Count -gt 0 -and $dirty.Count -le 10) { $dirty | ForEach-Object { Write-Host "               $_" } }
if ($dirty.Count -gt 10) { Write-Host ("               ... and {0} more" -f ($dirty.Count - 10)) }

$stash = @(git stash list)
Line 'stash' ("$($stash.Count) entr(y|ies)")
if ($stash.Count -gt 0) {
    $auto = @($stash | Where-Object { $_ -match 'auto-stash before sync' }).Count
    if ($auto -gt 0) {
        Write-Host ("               {0} of them are 'auto-stash before sync' (watcher artifacts, regenerated every round)" -f $auto) -ForegroundColor Yellow
        Write-Host "               inspect: git stash show --stat stash@{0}   then: git stash clear" -ForegroundColor Yellow
    }
    Write-Host "               recover with: git stash pop   (or 'git stash drop' to throw away)" -ForegroundColor Yellow
}

# ----------------------------------------------------------- lfs / big files
Write-Host ""
Write-Host "== large files / lfs" -ForegroundColor Cyan
$lfsVer = (git lfs version) 2>$null
if ("$lfsVer" -match 'git-lfs') {
    Line 'lfs' (("$lfsVer").Split(' ')[0])
} else {
    Line 'lfs' 'not installed (optional - only needed for big files)' 'DarkGray'
}
$big = @(git ls-files | ForEach-Object {
    $p = Join-Path $repo $_
    if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p -ErrorAction SilentlyContinue }
} | Where-Object { $_.Length -gt 50MB } | Select-Object -First 5)
if ($big.Count -gt 0) {
    foreach ($b in $big) {
        Line 'big file' ("{0}  ({1:N0} MB)  - consider Git LFS" -f $b.FullName.Substring($repo.Length + 1), ($b.Length / 1MB)) 'Yellow'
    }
} else {
    Line 'big file' 'none over 50 MB'
}

# ------------------------------------------- watcher / auth (auto-verification)
Write-Host ""
Write-Host "== auto-verification (watcher + auth)" -ForegroundColor Cyan
$leaf = Split-Path -Leaf $repo
$taskName = 'git-sync-watch-' + $leaf
$t = $null
try { $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { }
if ($t) {
    $mode = 'flash (hidden powershell)'
    try {
        $exec  = [string]$t.Actions[0].Execute
        $logon = [string]$t.Principal.LogonType
        if ($logon -eq 'S4U' -or $logon -eq 'Password') { $mode = 'headless (session 0)' }
        elseif ($exec -match 'watchhost') { $mode = 'zero-window (no flash)' }
    } catch { }
    $line = "$($t.State) | mode: $mode"
    $tn = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    # Scheduled-task result codes that are NORMAL for a long-lived loop - only
    # anything outside this list deserves a warning:
    #   0            completed
    #   267009       0x41301  the task is running right now (the loop never exits)
    #   267011       0x41303  the task has never run yet (just registered)
    #   267014       0x41306  terminated by the user (-Pause / -Unregister)
    #   2147946720   0x800710E0 launch refused because an instance is already
    #                running - exactly what the 10-min keeper trigger produces
    $okResults = @(0, 267009, 267011, 267014, 2147946720)
    $resCode = $null
    $resNote = ''
    if ($tn) {
        try { $resCode = [int64]$tn.LastTaskResult } catch { $resCode = $null }
        if ($null -ne $resCode) {
            switch ($resCode) {
                0          { $resNote = 'completed' }
                267009     { $resNote = 'still running (0x41301) - normal for the long-lived loop' }
                267011     { $resNote = 'has never run yet (0x41303)' }
                267014     { $resNote = 'terminated by the user (0x41306)' }
                2147946720 { $resNote = 'launch refused (0x800710E0) - an instance is already running; normal with the keeper trigger' }
                default    { $resNote = '' }
            }
        }
        $shown = "$($tn.LastTaskResult)"
        if ($resNote) { $shown = $shown + ' = ' + $resNote }
        $line += " | last run: $($tn.LastRunTime) | result: $shown"
    }
    Line 'watcher' $line
    if ($tn -and $null -ne $resCode -and ($okResults -notcontains $resCode)) {
        Write-Host "               last run did not finish cleanly (result $resCode) - check .\watch.ps1 -Status and $env:LOCALAPPDATA\git-sync\watch-$leaf.log" -ForegroundColor Yellow
    }
} else {
    Line 'watcher' 'not registered - run .\watch.ps1 -Register (auto-verification is OFF)' 'Yellow'
}
$stateDir  = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'git-sync' } else { Join-Path $env:TEMP 'git-sync' }
$stateFile = Join-Path $stateDir ('watch-' + $leaf + '.json')
if (Test-Path -LiteralPath $stateFile) {
    try {
        $hb = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Line 'heartbeat' ("$($hb.last_run) | action: $($hb.last_action) | round: $($hb.last_round) | verdict: $($hb.last_verdict) | push: $($hb.last_push)")
    } catch { Line 'heartbeat' '(unreadable)' 'Yellow' }
} else {
    Line 'heartbeat' '(none yet - the watcher has never completed a poll)' 'Yellow'
}
if ($cfg) {
    $hf = $false; $ap = $false; $au = $false
    try { if ($null -ne $cfg.hands_free) { $hf = [bool]$cfg.hands_free } } catch { }
    try { if ($null -ne $cfg.auto_pull)  { $ap = [bool]$cfg.auto_pull } } catch { }
    try { if ($null -ne $cfg.auto_push)  { $au = [bool]$cfg.auto_push } } catch { }
    if ($hf) { $ap = $true; $au = $true }
    Line 'hands-free' ("master=$hf auto_pull=$ap auto_push=$au")
}
$otherTasks = @()
try { $otherTasks = @(Get-ScheduledTask -TaskName 'git-sync-watch-*' -ErrorAction SilentlyContinue) } catch { }
$otherTasks = @($otherTasks | Where-Object { [string]$_.TaskName -ne $taskName })
if ($otherTasks.Count -gt 0) {
    $bits = @($otherTasks | ForEach-Object { ('{0}[{1}]' -f $_.TaskName, $_.State) })
    Line 'other tasks' (($bits -join '  ') + '  - .\\watch.ps1 -Focus parks them')
}
$parkFile = Join-Path $stateDir 'parked.json'
if (Test-Path -LiteralPath $parkFile) {
    try {
        $pl = Get-Content -LiteralPath $parkFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $pc = 0
        if ($pl.items) { $pc = @($pl.items).Count }
        if ($pc -gt 0) {
            Line 'parked' ("$pc task(s) by $($pl.last_focus) - restore: .\\watch.ps1 -RestoreParked") 'Yellow'
        }
    } catch { }
}
$authScript = Join-Path $repo 'auth.ps1'
if (Test-Path -LiteralPath $authScript) {
    try {
        # one probe, report-only flags: no -Setup/-Verify side effects here.
        # (-Verify would push a dry-run AND add git's binary progress bar to
        #  the parse stream, which is more noise than this line is worth.)
        $authJson = (& $authScript -Json | Out-String)
        $auth = $null
        foreach ($ln in ($authJson -split "`r?`n")) {
            if ($ln -match '^\s*\{') { $auth = $ln | ConvertFrom-Json; break }
        }
        if ($auth) {
            $remoteExists = $false
            $probe = git -c credential.interactive=false rev-parse --verify --quiet ("refs/remotes/$remoteName/$wantBranch") 2>$null
            if ($LASTEXITCODE -eq 0) { $remoteExists = $true }
            if ($auth.ready) {
                Line 'auth' ("ready - $($auth.credential_detail)") 'Green'
            } elseif (-not $remoteExists) {
                Line 'auth' 'probe only (the remote branch is not fetched yet - no verdict)' 'DarkGray'
            } else {
                Line 'auth' 'NOT ready - run .\auth.ps1 -Setup (a push would need a click)' 'Yellow'
            }
            Line 'auth how' ("helper=$($auth.credential_helper) store=$($auth.credential_store) gh=$($auth.gh_state) scheme=$($auth.scheme)")
            # multi-account: one machine, several GitHub logins (v2.9.0)
            if ($auth.pinned_account) {
                Line 'auth account' ("this clone is PINNED to $($auth.pinned_account) - gh active: $($auth.active_account)") 'Green'
            } elseif ($auth.active_account) {
                Line 'auth account' ("gh active account: $($auth.active_account) - no per-clone pin (repo $($auth.repo_slug))")
                if ($auth.accounts -and @($auth.accounts).Count -gt 1) {
                    Line 'auth switch' ("more logins available: $(@($auth.accounts) -join ', ') - .\auth.ps1 -Accounts")
                }
            }
        } else {
            Line 'auth' '(no json from auth.ps1 - run .\auth.ps1 by hand)' 'Yellow'
        }
    } catch { Line 'auth' '(probe failed - run .\auth.ps1 to see why)' 'Yellow' }
} else {
    Line 'auth' '(auth.ps1 missing - upgrade the skill)' 'Yellow'
}

Write-Host ""
Write-Host "== last commits" -ForegroundColor Cyan
git log -3 --oneline --decorate

Write-Host ""
Write-Host "== next steps" -ForegroundColor Cyan
Write-Host "   .\sync.ps1                       pull the latest from the working branch"
Write-Host "   .\push.ps1 `"msg`"                commit + push local changes"
Write-Host "   .\download.ps1 -Set final        copy deliverables out of the repo"
Write-Host "   .\download.ps1 -Set final -Since 2026-09-14   only files changed since a date"
Write-Host "   .\pr.ps1                         open a PR from the working branch to main"
Write-Host "   .\auth.ps1 (-Setup / -Verify)    make pushes silent: no popup, no click"
Write-Host "   .\watch.ps1 -Status / -Test      is the auto-verification watcher alive?"
Write-Host "   .\watch.ps1 -Register            run the local checks the agent asks for"
Write-Host "   .\watch.ps1 -Focus               pause other conversations' watchers (this one stays)"
Write-Host "   .\watch.ps1 -RestoreParked       resume the watchers -Focus paused"
Write-Host "   .\watch.ps1 -Status              hands-free line: master/auto_pull/auto_push"

# ---------------------------------------------------------------------- fix
if ($Fix) {
    Write-Host ""
    Write-Host "== fixing" -ForegroundColor Cyan
    git config "remote.$remoteName.fetch" "+refs/heads/*:refs/remotes/$remoteName/*"
    Write-Host "   fetch refspec rebuilt for '$remoteName'"
    if (git status --porcelain) {
        git stash push -u -m ("doctor -Fix " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Write-Host "   uncommitted changes stashed  (recover: git stash pop)"
    }
    if ($wantBranch -and $branch -ne $wantBranch) {
        git checkout $wantBranch
        if ($LASTEXITCODE -eq 0) { Write-Host "   switched to $wantBranch" }
        else { Write-Host "   [ERROR] cannot check out $wantBranch" -ForegroundColor Red }
    } else {
        Write-Host "   already on the configured branch"
    }
    if ($wantBranch) {
        git pull --ff-only $remoteName $wantBranch
        if ($LASTEXITCODE -eq 0) { Write-Host "   pulled the latest" }
        else { Write-Host "   [ERROR] pull failed - see the message above" -ForegroundColor Red }
    }
    if (Test-Path -LiteralPath (Join-Path $repo 'auth.ps1')) {
        # -Fix never rewrites credentials on its own; it only says what is missing
        try {
            $auth = ((& (Join-Path $repo 'auth.ps1') -Json) | Out-String) | ConvertFrom-Json
            if (-not $auth.ready) { Write-Host "   tip: pushes are not silent yet - run .\auth.ps1 -Setup once" -ForegroundColor Yellow }
        } catch { }
    }
} else {
    Write-Host ""
    Write-Host "tip: .\doctor.ps1 -Fix rebuilds the fetch refspec, stashes stray changes," -ForegroundColor DarkGray
    Write-Host "     switches back to the configured branch and pulls." -ForegroundColor DarkGray
}
