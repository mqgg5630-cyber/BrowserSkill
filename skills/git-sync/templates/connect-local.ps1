# connect-local.ps1 - clone a working branch into a NEW folder and wire
# silent-push + watcher. ASCII-only (Windows PowerShell 5.1).
#
# Paste into PowerShell AFTER the agent replies with origin url + branch.
# Never use folder names: git-pull-arena / git-pull-arena-v268 / git-pull-arena-s2
#
#   cd E:\0github\git-sync
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\connect-local.ps1 `
#     -RepoUrl https://github.com/OWNER/REPO.git `
#     -Branch arena/xxxx-name `
#     -FolderName repo-xxxx

param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [Parameter(Mandatory = $true)][string]$Branch,
    [string]$Parent = 'E:\0github\git-sync',
    [string]$FolderName = ''
)

$ErrorActionPreference = 'Stop'
$blocked = @('git-pull-arena', 'git-pull-arena-v268', 'git-pull-arena-s2')

if (-not $FolderName) {
    $repoLeaf = [IO.Path]::GetFileNameWithoutExtension(($RepoUrl -replace '\.git$', '').TrimEnd('/'))
    $short = ($Branch -replace '^arena/', '')
    if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
    $FolderName = $repoLeaf + '-' + $short
}

foreach ($b in $blocked) {
    if ($FolderName -eq $b) {
        Write-Host ("[REFUSED] folder '" + $FolderName + "' is frozen - pick another -FolderName") -ForegroundColor Red
        exit 1
    }
}

if ($Branch -in @('main', 'master')) {
    Write-Host '[REFUSED] never clone main/master as the working branch' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
}

$dest = Join-Path $Parent $FolderName
if (Test-Path -LiteralPath $dest) {
    Write-Host ("[REFUSED] already exists: " + $dest + " - pick another -FolderName") -ForegroundColor Red
    exit 1
}

Write-Host ("== parent : " + $Parent)
Write-Host ("== folder : " + $FolderName)
Write-Host ("== branch : " + $Branch)
Write-Host ("== url    : " + $RepoUrl)

Set-Location $Parent
git clone -b $Branch $RepoUrl $FolderName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location $dest

if (Test-Path -LiteralPath '.\bootstrap.ps1') {
    & .\bootstrap.ps1 -Auto
} else {
    Write-Host '[ERROR] bootstrap.ps1 missing - skill not on this branch?' -ForegroundColor Red
    exit 1
}

if (Test-Path -LiteralPath '.\doctor.ps1') { & .\doctor.ps1 }
if (Test-Path -LiteralPath '.\watch.ps1') { & .\watch.ps1 -Status }

Write-Host ''
Write-Host ('== ready: ' + $dest)
Write-Host '   daily: .\sync.ps1   /   .\push.ps1 "msg"   /   .\watch.ps1 -Status'
Write-Host '   this clone only: .\watch.ps1 -Focus     (parks other git-sync-watch-* tasks)'
Write-Host '   resume parked:   .\watch.ps1 -RestoreParked'
Write-Host '   HQ clone:        cd E:\0github\git-sync\git-pull-arena-s2 ; .\watch.ps1 -Focus'
