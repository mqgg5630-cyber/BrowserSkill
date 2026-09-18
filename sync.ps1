# sync.ps1 (skill version) - pull the latest code from the working branch.
#
# Usage (inside the repo folder):
#     .\sync.ps1
#     .\sync.ps1 -Branch arena/01a09d79-zhongqi
#
# The branch defaults to sync.config.json (keys: branch / remote), so the same
# script works in any repo that carries that file.
#
# WATCHER-SAFE BY DESIGN (field report 2026-09-16):
#   * every git call goes through cmd.exe, because PowerShell 5.1 turns a native
#     command's STDERR into a terminating error while $ErrorActionPreference is
#     'Stop' - and git writes perfectly normal things ("Already on 'x'",
#     "Switched to branch ...") to stderr. That killed the watcher's poll
#     halfway through, so the verdict was never pushed.
#   * the watcher's own artifacts (results/status/*) are committed locally
#     instead of stashed, and an unpushed artifact commit is AMENDED instead of
#     piling up one commit per round (313 had accumulated in the field).
#
# ASCII-only on purpose: Windows PowerShell 5.1 decodes a .ps1 without BOM as
# ANSI/GBK and non-ASCII text would break the parser.

param(
    [string]$Branch = '',
    [string]$Remote = '',
    [string]$Config = ''
)

$ErrorActionPreference = 'Continue'

# run git through cmd.exe: stderr stays stderr (no terminating ErrorRecord) and
# the exit code is git's own
function Git {
    param([string[]]$ArgList, [switch]$Show)
    $line = 'git'
    foreach ($a in $ArgList) {
        if ($a -match '[\s"]') { $line += ' "' + ($a -replace '"', '""') + '"' } else { $line += ' ' + $a }
    }
    $out = (cmd /c ($line + ' 2>&1') | Out-String)
    $code = $LASTEXITCODE
    if ($Show -and $out.TrimEnd()) { Write-Host $out.TrimEnd() }
    return @{ code = $code; text = $out.TrimEnd() }
}

# repo root = walk up from this script until .git appears, so the script also
# works when run straight from skills\git-sync\scripts\
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    $up = Split-Path -Parent $repo
    if (-not $up -or $up -eq $repo) { break }
    $repo = $up
}
Set-Location -LiteralPath $repo

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    Write-Host "[ERROR] Not a git repository: $repo" -ForegroundColor Red
    Write-Host "        Run this from the cloned folder (e.g. E:\0zhongqi\zhongqi)." -ForegroundColor Red
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
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $Branch -and $cfg.branch) { $Branch = [string]$cfg.branch }
    if (-not $Remote -and $cfg.remote) { $Remote = [string]$cfg.remote }
}
if (-not $Remote) { $Remote = 'origin' }
if (-not $Branch) { $Branch = (Git @('rev-parse', '--abbrev-ref', 'HEAD')).text }

Write-Host "== repo  : $repo" -ForegroundColor Cyan
Write-Host "== branch: $Branch" -ForegroundColor Cyan

$remoteRef = "$Remote/$Branch"

# ---- realign when the only local commits are the watcher's own verdicts -----
# A push that failed leaves "check: round N <verdict>" / "watch: local check
# artifacts ..." commits behind. They are regenerated every round, so they must
# not block the fast-forward (they used to stall the watcher forever), but they
# are dropped ONLY when every local commit matches that pattern.
function Get-AheadSubjects {
    $r = Git @('log', '--format=%s', "$remoteRef..HEAD")
    if ($r.code -ne 0) { return @() }
    return @($r.text -split "`r?`n" | Where-Object { $_ -match '\S' })
}
$ahead = Get-AheadSubjects
if ($ahead.Count -gt 0) {
    $onlyArtifacts = $true
    foreach ($subj in $ahead) {
        if ($subj -notmatch '^(check: round|watch: local check artifacts)') { $onlyArtifacts = $false; break }
    }
    if ($onlyArtifacts) {
        Write-Host ("== {0} local commit(s) are only watcher verdicts - realigning with $remoteRef (files are kept)" -f $ahead.Count) -ForegroundColor Cyan
        $null = Git @('reset', '--mixed', $remoteRef)
        # restore anything the reset removed from the worktree (the verdict logs)
        $deleted = (Git @('ls-files', '--deleted')).text
        foreach ($d in @($deleted -split "`r?`n" | Where-Object { $_ -match '\S' })) {
            $null = Git @('checkout', '--', $d)
        }
    } else {
        Write-Host ("== {0} local commit(s) exist that are NOT watcher verdicts - they will be pushed, not dropped" -f $ahead.Count) -ForegroundColor Yellow
    }
}

# ---- local changes ---------------------------------------------------------
$dirty = @((Git @('status', '--porcelain')).text -split "`r?`n" | Where-Object { $_ -match '\S' })
$stashed = $false
$artifactCommitted = $false
if ($dirty.Count -gt 0) {
    $watcherOnly = $true
    foreach ($line in $dirty) {
        $p = $line.Substring(3).Trim().Trim('"')
        if ($p -notmatch '^results/status/') { $watcherOnly = $false; break }
    }
    if ($watcherOnly) {
        Write-Host "== local changes are watcher artifacts (results/status/) - committing them instead of stashing" -ForegroundColor Cyan
        $null = Git @('add', '-A', '--', 'results/status')
        # AMEND while the tip is still unpushed: one artifact commit per repo,
        # not one per round (313 had piled up in the field)
        $tipSubject = (Git @('log', '-1', '--format=%s')).text
        $unpushed = (Git @('rev-list', '--count', "$remoteRef..HEAD")).text
        $amend = ($tipSubject -match '^watch: local check artifacts' -and [int]$unpushed -ge 1)
        $msg = "watch: local check artifacts " + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        if ($amend) { $null = Git @('-c', 'user.name=git-sync watcher', '-c', 'user.email=watcher@local', 'commit', '-q', '--amend', '--no-edit') }
        else        { $null = Git @('-c', 'user.name=git-sync watcher', '-c', 'user.email=watcher@local', 'commit', '-q', '-m', $msg) }
        $artifactCommitted = $true
    } else {
        Write-Host "!! local changes found, stashing them first ..." -ForegroundColor Yellow
        $null = Git @('stash', 'push', '-u', '-m', ("auto-stash before sync " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        $stashed = $true
    }
}

$fetch = Git @('fetch', $Remote)
if ($fetch.code -ne 0) {
    Write-Host "[ERROR] git fetch failed (network / proxy?)." -ForegroundColor Red
    if ($fetch.text) { Write-Host $fetch.text -ForegroundColor DarkGray }
    exit 1
}

$null = Git @('checkout', $Branch) -Show
$pull = Git @('pull', '--ff-only', $Remote, $Branch) -Show
if ($pull.code -ne 0) {
    Write-Host "[ERROR] pull failed. Your branch has local commits that conflict." -ForegroundColor Red
    Write-Host "        Diagnose: git status ; git stash list ; git log --oneline -5" -ForegroundColor Yellow
    Write-Host "        Hard reset (loses local commits): git reset --hard $remoteRef" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "== up to date. latest commit:" -ForegroundColor Green
$null = Git @('log', '-1', '--oneline', '--decorate') -Show

if ($stashed) {
    Write-Host ""
    Write-Host "NOTE: your previous local changes are still in the stash. See: git stash list" -ForegroundColor Yellow
}
if ($artifactCommitted) {
    Write-Host "NOTE: watcher artifacts were committed locally and will be pushed with the next push." -ForegroundColor DarkGray
}
$stashCount = @((Git @('stash', 'list')).text -split "`r?`n" | Where-Object { $_ -match '\S' }).Count
if ($stashCount -ge 3) {
    Write-Host ("NOTE: {0} stash entries are piling up - inspect with 'git stash list' and drop the auto-stash ones." -f $stashCount) -ForegroundColor Yellow
}
