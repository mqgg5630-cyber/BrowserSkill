# bootstrap.ps1 - first-time setup for a fresh clone (run once, inside the repo).
#
# Usage (inside the repo folder):
#     .\bootstrap.ps1
#     .\bootstrap.ps1 -Branch arena/01a09d79-zhongqi
#     .\bootstrap.ps1 -Auto            # also: silent-push auth + register the watcher
#
# It will:
#   1. allow local scripts for the current user (RemoteSigned)
#   2. set a repo-local git identity if none is configured (so commits work)
#   3. fetch, then check out the working branch and fast-forward it
#   4. print the three commands of the daily workflow
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [string]$Branch = '',
    [string]$Remote = 'origin',
    [string]$Config = '',
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'

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
    Write-Host "[ERROR] not a git repository: $repo" -ForegroundColor Red
    Write-Host "        clone it first:  git clone <url> <folder>" -ForegroundColor Yellow
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
    if (-not $Branch) { $Branch = [string]$cfg.branch }
    if ($cfg.remote)  { $Remote = [string]$cfg.remote }
}
if (-not $Branch) { $Branch = (git rev-parse --abbrev-ref HEAD).Trim() }

Write-Host "== repo   : $repo" -ForegroundColor Cyan
Write-Host "== branch : $Branch" -ForegroundColor Cyan

# ------------------------------------------------------------- 1. policy
try {
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq 'Undefined' -or $policy -eq 'Restricted') {
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
        Write-Host "== execution policy set to RemoteSigned (CurrentUser)" -ForegroundColor Green
    } else {
        Write-Host "== execution policy already $policy" -ForegroundColor Green
    }
} catch {
    Write-Host "== could not change the execution policy (run PowerShell as your own user)" -ForegroundColor Yellow
}

# --------------------------------------------------------- 2. git identity
if (-not (git config user.name)) {
    git config user.name  'mqgg5630-cyber'
    git config user.email 'mqgg5630-cyber@users.noreply.github.com'
    Write-Host "== set a repo-local git identity (change with: git config user.name ...)" -ForegroundColor Yellow
} else {
    Write-Host ("== git identity: {0}" -f (git config user.name)) -ForegroundColor Green
}

# ------------------------------------------------------------- 3. get files
git fetch $Remote
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] git fetch failed (network?)" -ForegroundColor Red; exit 1 }

git checkout $Branch
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] cannot check out $Branch" -ForegroundColor Red; exit 1 }

git pull --ff-only $Remote $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] pull --ff-only failed - you have local commits that diverged." -ForegroundColor Red
    Write-Host "        Inspect with: git status" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "== ready. latest commit:" -ForegroundColor Green
git log -1 --oneline --decorate

# ------------------------------------------- 4. optional: unattended plumbing
if ($Auto) {
    Write-Host ""
    Write-Host "== -Auto: making pushes silent and starting the watcher" -ForegroundColor Cyan
    $auth = Join-Path $repo 'auth.ps1'
    if (Test-Path -LiteralPath $auth) {
        & $auth -Setup
    } else {
        Write-Host "   (auth.ps1 missing - upgrade the skill)" -ForegroundColor Yellow
    }
    $watch = Join-Path $repo 'watch.ps1'
    if (Test-Path -LiteralPath $watch) {
        & $watch -Register
    } else {
        Write-Host "   (watch.ps1 missing - upgrade the skill)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "== daily workflow" -ForegroundColor Cyan
Write-Host "   .\sync.ps1                 pull the latest"
Write-Host "   .\upload.ps1               upload local attachments + push"
Write-Host "   .\download.ps1 -Set final  copy the deliverables out"
Write-Host "   .\doctor.ps1               health check when something looks wrong"
Write-Host "   .\auth.ps1 -Setup          one time: pushes stop asking for a click"
Write-Host "   .\watch.ps1 -Register      one time: auto-verify what the agent builds"
if (-not $Auto) {
    Write-Host ""
    Write-Host "   (or run .\bootstrap.ps1 -Auto once to do the last two for you)" -ForegroundColor DarkGray
}
