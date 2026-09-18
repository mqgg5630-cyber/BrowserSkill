# pr.ps1 - open (or check) a pull request from the working branch to main,
# using the GitHub CLI (gh).
#
# Usage (inside the repo folder):
#     .\pr.ps1                          # PR working branch -> main
#     .\pr.ps1 -Title "sync skill v2" -Body "what changed"
#     .\pr.ps1 -Base develop            # a different base branch
#     .\pr.ps1 -Checks                  # show the CI checks of the open PR
#
# Needs the GitHub CLI once:  winget install GitHub.cli   then  gh auth login
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [string]$Title  = '',
    [string]$Body   = '',
    [string]$Base   = 'main',
    [string]$Config = '',
    [switch]$Checks
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
    Write-Host "[ERROR] Not a git repository: $repo" -ForegroundColor Red
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

$Branch = ''
$Remote = ''
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($cfg.branch) { $Branch = [string]$cfg.branch }
    if ($cfg.remote) { $Remote = [string]$cfg.remote }
}
if (-not $Remote) { $Remote = 'origin' }
if (-not $Branch) { $Branch = (git rev-parse --abbrev-ref HEAD).Trim() }

# -------------------------------------------------------------------- guard
if ($Branch -eq 'main' -or $Branch -eq 'master') {
    Write-Host "[REFUSED] the working branch is $Branch - there is nothing to pull request." -ForegroundColor Red
    exit 1
}
if ($Branch -eq $Base) {
    Write-Host "[REFUSED] base and head are both $Base." -ForegroundColor Red
    exit 1
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] GitHub CLI (gh) not found." -ForegroundColor Red
    Write-Host "        Install it once with:  winget install GitHub.cli" -ForegroundColor Yellow
    Write-Host "        then log in with:       gh auth login" -ForegroundColor Yellow
    exit 1
}

# -------------------------------------------------------------------- checks
if ($Checks) {
    Write-Host "== checks for $Branch :" -ForegroundColor Cyan
    gh pr checks $Branch
    exit $LASTEXITCODE
}

# -------------------------------------------------------------------- create
if (-not $Title) { $Title = (git log -1 --pretty=%s) }
if (-not $Body) {
    try { $commits = (git log --oneline ("{0}..{1}" -f $Base, $Branch)) -join "`n" } catch { $commits = '' }
    if (-not $commits) { $commits = '(no commits listed)' }
    $Body = "Commits:`n`n$commits"
}

Write-Host "== creating PR: $Branch -> $Base" -ForegroundColor Cyan
Write-Host "   title: $Title"
gh pr create --base $Base --head $Branch --title $Title --body $Body
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  * a PR may already exist:  gh pr view $Branch --web" -ForegroundColor Yellow
    Write-Host "  * auth problem:            gh auth login" -ForegroundColor Yellow
    exit 1
}
Write-Host ""
Write-Host "== PR created. CI checks (GitHub Actions) show up with:" -ForegroundColor Green
Write-Host "   .\pr.ps1 -Checks"
