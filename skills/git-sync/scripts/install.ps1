# install.ps1 - copy the sync toolkit into another repo and write its config.
#
# Usage (from anywhere):
#     .\install.ps1 -Target C:\MyProject
#     .\install.ps1 -Target C:\MyProject -Branch main -DownloadDir "C:\out"
#     .\install.ps1 -Target E:\0github\git-sync\zhongqi -Branch arena/01a09d79-zhongqi
#
# It installs into the target repo:
#     skills\git-sync\...        the complete skill (docs + scripts + templates)
#     sync.ps1 push.ps1 ...      the user-side scripts at the repo root
#     sync.config.json           created, or KEPT when upgrading (only the
#                                branch moves; sets / upload_map / gate stay)
# and creates code\check_all.sh + the code\*.{py,ps1} gate helpers when the
# target has none of its own. Everything under code\ that the target already
# has is left alone (create-only): those files belong to the repo, and a
# hand-edited local_check.ps1 must survive an upgrade.
#
# The .ps1 files stay ASCII; only the JSON carries folder names.
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Branch      = '',
    [string]$Remote      = 'origin',
    [string]$DownloadDir = ''
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# This script ships TWICE and both copies must stay byte-identical (the gate
# checks it): the repo root and skills\git-sync\scripts. So work out which one
# we are instead of assuming ".." is the skill folder.
$src = $null
foreach ($cand in @((Join-Path $here '..'), $here, (Join-Path $here 'skills\git-sync'))) {
    if (Test-Path -LiteralPath (Join-Path $cand 'scripts\install.ps1')) {
        $src = (Resolve-Path -LiteralPath $cand).Path
        break
    }
}
if (-not $src) {
    throw "cannot find the git-sync skill folder (looked next to $here for scripts\install.ps1)"
}

if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
}

Write-Host "source : $src"
Write-Host "target : $Target"

# 1. the complete skill folder
$skillDst = Join-Path $Target 'skills\git-sync'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillDst) | Out-Null
Copy-Item -Recurse -Force -LiteralPath $src -Destination $skillDst
Write-Host "  copied skills\git-sync (docs + scripts + templates)"

# 2. the user-side scripts at the repo root
$files = @('sync.ps1', 'push.ps1', 'upload.ps1', 'download.ps1',
           'doctor.ps1', 'pack.ps1', 'bootstrap.ps1', 'pr.ps1',
           'hardware.ps1', 'watch.ps1', 'auth.ps1', 'install.ps1')
foreach ($f in $files) {
    $from = Join-Path $src ('scripts\' + $f)
    if (Test-Path -LiteralPath $from) {
        Copy-Item -Force -LiteralPath $from -Destination (Join-Path $Target $f)
        Write-Host "  copied $f"
    } else {
        Write-Host "  MISSING $f" -ForegroundColor Yellow
    }
}

# 3. the gate (only when the target repo has none of its own)
$gateSrc = Join-Path $src 'templates\check_all.sh'
$gateDst = Join-Path $Target 'code\check_all.sh'
if ((Test-Path -LiteralPath $gateSrc) -and -not (Test-Path -LiteralPath $gateDst)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Target 'code') | Out-Null
    Copy-Item -Force -LiteralPath $gateSrc -Destination $gateDst
    Write-Host "  created code\check_all.sh (gate)"
}

# 3b. the gate helper that catches "$var:" typos (create only)
$scanSrc = Join-Path $src 'templates\scan_ps_var_colon.py'
$scanDst = Join-Path $Target 'code\scan_ps_var_colon.py'
if ((Test-Path -LiteralPath $scanSrc) -and -not (Test-Path -LiteralPath $scanDst)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Target 'code') | Out-Null
    Copy-Item -Force -LiteralPath $scanSrc -Destination $scanDst
    Write-Host "  created code\scan_ps_var_colon.py (gate helper)"
}

# 3c. the gate helper that proves every watcher poll exit prints a closing
#     line (create only - a repo may have edited its own copy)
foreach ($helper in @('check_loop_summary.py', 'check_loop_summary.ps1')) {
    $hSrc = Join-Path $src ('templates\' + $helper)
    $hDst = Join-Path $Target ('code\' + $helper)
    if ((Test-Path -LiteralPath $hSrc) -and -not (Test-Path -LiteralPath $hDst)) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Target 'code') | Out-Null
        Copy-Item -Force -LiteralPath $hSrc -Destination $hDst
        Write-Host ("  created code\" + $helper + " (gate helper)")
    }
}

# 3d. short-prompt mapping page (arena.ai/01a0a821 -> GitHub clone)
$mapSrc = Join-Path $src 'templates\01a0a821.md'
$mapDst = Join-Path $Target '01a0a821.md'
if (Test-Path -LiteralPath $mapSrc) {
    Copy-Item -Force -LiteralPath $mapSrc -Destination $mapDst
    Write-Host "  copied 01a0a821.md (short prompt maps to GitHub clone)"
}

# 4. the config: create, or keep an existing one on upgrade
$cfgSrc = Join-Path $src 'sync.config.json'
$cfgDst = Join-Path $Target 'sync.config.json'
if (Test-Path -LiteralPath $cfgDst) {
    # upgrade: never throw away the target's sets / upload_map / gate
    $cfg = Get-Content -LiteralPath $cfgDst -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($Branch) { $cfg.branch = $Branch }
    if ($DownloadDir) { $cfg.download_dir = $DownloadDir }
    if (-not $cfg.PSObject.Properties.Match('receipt')) {
        $cfg | Add-Member -NotePropertyName receipt -NotePropertyValue 'results/sync/last_sync.md'
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgDst -Encoding UTF8
    Write-Host "  kept   sync.config.json (existing sets / map / gate kept, branch updated)"
} elseif (Test-Path -LiteralPath $cfgSrc) {
    $cfg = Get-Content -LiteralPath $cfgSrc -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($Branch)      { $cfg.branch = $Branch }
    if ($Remote)      { $cfg.remote = $Remote }
    if ($DownloadDir) { $cfg.download_dir = $DownloadDir }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgDst -Encoding UTF8
    Write-Host "  wrote  sync.config.json"
} else {
    Write-Host "  sync.config.json template missing - skipped" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "== next steps in $Target" -ForegroundColor Cyan
Write-Host "   .\bootstrap.ps1                 first-time setup (policy, identity, branch)"
Write-Host "   .\sync.ps1 / .\push.ps1         pull / commit+push"
Write-Host "   .\upload.ps1 / .\download.ps1   put attachments in / copy deliverables out"
Write-Host "   .\download.ps1 -List            show the download sets"
Write-Host "   .\doctor.ps1 (-Fix)             health check (and auto-fix)"
Write-Host "   .\pr.ps1                        open a PR to main (needs GitHub CLI)"
Write-Host "   .\auth.ps1 -Setup / -Verify     make pushes silent (no popup, no click)"
Write-Host "   .\watch.ps1 -Register           auto-verify: run this repo's checks"
Write-Host "   edit sync.config.json to change the branch, sets or download folder"
