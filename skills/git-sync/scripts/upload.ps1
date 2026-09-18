# upload.ps1 (skill version) - ONE command: copy your files from a local folder
# into the repo, then commit + push them.
#
# Usage (inside the repo folder):
#     .\upload.ps1
#     .\upload.ps1 -Message "add midterm files"
#     .\upload.ps1 -Src "E:\0zhongqi\attachments"
#     .\upload.ps1 -Src "E:\data" -Ext ".csv",".xlsx" -Dest results
#
# Destination folders come from upload_map in sync.config.json
# (extension -> folder). Unknown extensions are reported and skipped.
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK);
# Chinese folder names never appear here - they live in the JSON config.

param(
    [string]$Src     = '',
    [string]$Message = '',
    [string[]]$Ext   = @(),
    [string]$Dest    = '',
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'

$repo   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# repo root = walk up from this script until .git appears, so the script also
# works when run straight from skills\git-sync\scripts\
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    $up = Split-Path -Parent $repo
    if (-not $up -or $up -eq $repo) { break }
    $repo = $up
}
$parent = Split-Path -Parent $repo
Set-Location -LiteralPath $repo

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    Write-Host "[ERROR] Not a git repository: $repo" -ForegroundColor Red
    Write-Host "        Run this from the cloned folder, e.g. E:\0zhongqi\zhongqi" -ForegroundColor Red
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

$map = @{}
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    foreach ($p in $cfg.upload_map.PSObject.Properties) { $map[$p.Name.ToLower()] = [string]$p.Value }
} else {
    $map = @{ '.docx' = 'sources'; '.doc' = 'sources'; '.pptx' = 'sources'; '.ppt' = 'sources'
              '.pdf' = 'sources'; '.md' = 'sources'; '.txt' = 'sources'
              '.py' = 'code'; '.xlsx' = 'results'; '.xls' = 'results'; '.csv' = 'results' }
    Write-Host "== sync.config.json not found, using the built-in extension map" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- find source
if (-not $Src) {
    $docExt = @('.docx', '.doc', '.pptx', '.ppt', '.pdf', '.xlsx', '.csv')
    $cand = Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $repo } |
        Where-Object {
            @(Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue |
              Where-Object { $docExt -contains $_.Extension.ToLower() }).Count -gt 0
        } | Select-Object -First 1
    if ($cand) { $Src = $cand.FullName }
}

if (-not $Src -or -not (Test-Path -LiteralPath $Src)) {
    Write-Host "[ERROR] Cannot locate the attachment folder automatically." -ForegroundColor Red
    Write-Host "        Pass it explicitly, e.g.:" -ForegroundColor Yellow
    Write-Host '        .\upload.ps1 -Src "E:\0zhongqi\<your folder>"' -ForegroundColor Yellow
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $Src -File -ErrorAction SilentlyContinue |
           Where-Object { $Ext.Count -eq 0 -or $Ext -contains $_.Extension.ToLower() })
if ($files.Count -eq 0) {
    Write-Host "[ERROR] No matching files in: $Src" -ForegroundColor Red
    exit 1
}

Write-Host "== source: $Src" -ForegroundColor Cyan
Write-Host ("== {0} file(s) found" -f $files.Count) -ForegroundColor Cyan

# ------------------------------------------------------------------ copy them
$copied = 0
foreach ($f in $files) {
    $ext = $f.Extension.ToLower()
    $target = if ($Dest) { $Dest } else { $map[$ext] }
    if (-not $target) {
        Write-Host ("   skip  {0}  (extension not mapped - add it to upload_map)" -f $f.Name) -ForegroundColor DarkGray
        continue
    }
    $dir = Join-Path $repo $target
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir $f.Name) -Force
    Write-Host ("   add   {0}  ->  {1}\" -f $f.Name, $target) -ForegroundColor Green
    $copied++
}

if ($copied -eq 0) {
    Write-Host "[ERROR] Nothing was copied - check the file extensions." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------- and push
$push = Join-Path $repo 'push.ps1'
if (-not (Test-Path -LiteralPath $push)) { $push = Join-Path $PSScriptRoot 'push.ps1' }
if ([string]::IsNullOrWhiteSpace($Message)) { $Message = 'upload: local documents and data' }

Write-Host ""
if (Test-Path -LiteralPath $push) {
    & $push $Message
} else {
    Write-Host "push.ps1 not found, doing it inline:" -ForegroundColor Yellow
    git add -A
    git commit -m $Message
    git push origin HEAD
}
