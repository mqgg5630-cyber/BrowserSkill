# pack.ps1 - zip a download set (deliverables etc.) into one archive to hand in.
#
# Usage (inside the repo folder):
#     .\pack.ps1                        # default set "final" -> _export\<date>_final.zip
#     .\pack.ps1 -Set final -Out "E:\submission\midterm.zip"
#     .\pack.ps1 -Set preview
#
# The set names and folder names come from sync.config.json (UTF-8), so this
# script stays ASCII-only (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).
#
# Compress-Archive needs PowerShell 5.0+ (any Windows 10 / 11).

param(
    [string]$Set = 'final',
    [string]$Out = '',
    [string]$Config = ''
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
if (-not $cfgPath) { Write-Host "[ERROR] sync.config.json not found" -ForegroundColor Red; exit 1 }

$cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
$setNames = @($cfg.download_sets.PSObject.Properties | ForEach-Object { $_.Name })
if ($setNames -notcontains $Set) {
    Write-Host ("[ERROR] unknown set '{0}'. Available: {1}" -f $Set, ($setNames -join ', ')) -ForegroundColor Red
    exit 1
}

# collect the files (staging in the temp folder keeps _export clean)
$stage = Join-Path $env:TEMP ('pack_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$count = 0
foreach ($rel in @($cfg.download_sets.$Set)) {
    $src = Join-Path $repo $rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (Test-Path -LiteralPath $src -PathType Container) {
        $dst = Join-Path $stage $rel
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        robocopy $src $dst /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        $count += @(Get-ChildItem -LiteralPath $src -Recurse -File).Count
    } else {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage (Split-Path -Leaf $src)) -Force
        $count++
    }
}

if ($count -eq 0) {
    Write-Host "[ERROR] nothing to pack - check the set name and the folder names" -ForegroundColor Red
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    exit 1
}

if (-not $Out) {
    $exportDir = Join-Path $repo '_export'
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    $Out = Join-Path $exportDir ("{0}_{1}.zip" -f $stamp, $Set)
}
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Out -CompressionLevel Optimal
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

$size = (Get-Item -LiteralPath $Out).Length / 1MB
Write-Host ""
Write-Host ("== packed {0} file(s) from set '{1}'" -f $count, $Set) -ForegroundColor Green
Write-Host ("== archive: {0}  ({1:N1} MB)" -f $Out, $size) -ForegroundColor Green
Write-Host "== note: _export\ is git-ignored, so the zip will not be uploaded by push.ps1" -ForegroundColor DarkGray
