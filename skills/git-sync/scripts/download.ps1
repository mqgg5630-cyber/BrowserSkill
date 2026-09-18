# download.ps1 - copy chosen folders FROM the repo TO a local folder (robocopy),
# or copy only the files that changed since a date (-Since).
#
# Usage (inside the repo folder):
#     .\download.ps1                    # default set "final" -> <parent>\<repo>_out
#     .\download.ps1 -Set final         # the deliverable folders (see -List)
#     .\download.ps1 -Set preview       # whatever the config defines
#     .\download.ps1 -Set all -Dest "E:\submission"
#     .\download.ps1 -Set final -Since 2026-09-14        # incremental: only
#     .\download.ps1 -Set final -Since "3 days ago"      # files git saw change
#     .\download.ps1 -Folders deliverable,examples\x     # ad-hoc: skip the sets
#     .\download.ps1 -List              # show the sets defined in sync.config.json
#
# -Since uses "git log --since" on the current branch, so run .\sync.ps1
# FIRST, otherwise the log (and the file list) is the old one.
#
# Folder names (including Chinese ones) live in sync.config.json, NOT in this
# file: Windows PowerShell 5.1 decodes a .ps1 without BOM as ANSI/GBK, so this
# script must stay pure ASCII. JSON is read explicitly as UTF-8.
#
# robocopy exit codes: 0-7 = OK/nothing to do, 8+ = real error.

param(
    [string]$Set    = 'final',
    [string[]]$Folders = @(),
    [string]$Dest   = '',
    [string]$Since  = '',
    [string]$Config = '',
    [switch]$Mirror,
    [switch]$List
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

if (-not $cfgPath) {
    Write-Host "[ERROR] sync.config.json not found next to this script or in skills\git-sync\." -ForegroundColor Red
    exit 1
}
$cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
Write-Host "== config: $cfgPath" -ForegroundColor Cyan

$setNames = @($cfg.download_sets.PSObject.Properties | ForEach-Object { $_.Name })

if ($List) {
    Write-Host "== available sets:" -ForegroundColor Cyan
    foreach ($p in $cfg.download_sets.PSObject.Properties) {
        Write-Host ("   {0,-8} {1}" -f $p.Name, ($p.Value -join ', '))
    }
    exit 0
}

if ($Folders.Count -gt 0) {
    # ad-hoc download: -Folders deliverable,examples\fig3-mechanism-map
    $folders = @($Folders)
    Write-Host "== folders: $($folders -join ', ')  (ad-hoc, -Folders)" -ForegroundColor Cyan
} else {
    if ($setNames -notcontains $Set) {
        Write-Host ("[ERROR] unknown set '{0}'. Available: {1}  (or pass -Folders a,b,c for an ad-hoc download)" -f $Set, ($setNames -join ', ')) -ForegroundColor Red
        exit 1
    }
    $folders = @($cfg.download_sets.$Set)
}

if (-not $Dest) {
    if ($cfg.download_dir) {
        $Dest = $cfg.download_dir
    } else {
        $Dest = Join-Path (Split-Path -Parent $repo) ((Split-Path -Leaf $repo) + '_out')
    }
}
if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }

Write-Host "== set    : $Set  ($($folders.Count) folder(s))" -ForegroundColor Cyan
Write-Host "== dest   : $Dest" -ForegroundColor Cyan

# ----------------------------------------------------------- incremental (-Since)
if ($Since) {
    Write-Host "== since  : $Since  (incremental - only files git logged as changed)" -ForegroundColor Cyan
    Write-Host "           (run .\sync.ps1 first, or the list reflects the old branch)" -ForegroundColor DarkGray
    $n = 0
    foreach ($rel in $folders) {
        $changed = @(git -c core.quotepath=false log "--since=$Since" --name-only --pretty=format: -- $rel |
                     Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $repo $_)) } |
                     Select-Object -Unique)
        if ($changed.Count -eq 0) {
            Write-Host ("   none  {0}  (nothing changed since {1})" -f $rel, $Since) -ForegroundColor DarkGray
            continue
        }
        foreach ($f in $changed) {
            $src = Join-Path $repo $f
            $dst = Join-Path $Dest $f
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host ("   copy  {0}" -f $f) -ForegroundColor Green
            $n++
        }
    }
    Write-Host ""
    if ($n -eq 0) {
        Write-Host "== nothing changed since $Since - no files copied." -ForegroundColor Green
    } else {
        Write-Host ("== done: {0} file(s) copied. latest commit:" -f $n) -ForegroundColor Green
    }
    git log -1 --oneline
    exit 0
}

# ---------------------------------------------------------------- full mirror
$fail = 0
foreach ($rel in $folders) {
    $src = Join-Path $repo $rel
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host ("   skip  {0}  (not in the repo)" -f $rel) -ForegroundColor DarkGray
        continue
    }
    $dst = Join-Path $Dest $rel
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $roboArgs = @($src, $dst, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1')
    if ($Mirror) { $roboArgs += '/MIR' }
    Write-Host ("   copy  {0}  ->  {1}" -f $rel, $Dest) -ForegroundColor Green
    robocopy @roboArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        Write-Host ("   [ERROR] robocopy failed on {0} (exit {1})" -f $rel, $code) -ForegroundColor Red
        $fail++
    }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "== done. latest commit:" -ForegroundColor Green
    git log -1 --oneline
} else {
    Write-Host ("== finished with {0} error(s)" -f $fail) -ForegroundColor Red
    exit 1
}
