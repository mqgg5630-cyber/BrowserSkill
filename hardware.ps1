# hardware.ps1 - collect this machine's hardware + python environment into
# results\hardware\ (latest.md / latest.json + dated snapshots) and push it,
# so the remote agent knows what it is working with (GPU, CPU, RAM, conda
# envs, CUDA...). Run once per machine, and again when hardware or envs
# change.
#
# Usage (inside the repo folder):
#     .\hardware.ps1              # collect + commit + push
#     .\hardware.ps1 -Deep        # also probe every conda env for torch/CUDA
#     .\hardware.ps1 -NoPush      # collect only (files stay uncommitted)
#
# The report location comes from sync.config.json (key: hardware_dir).
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK);
# system values (e.g. a Chinese OS caption) land in the .md/.json data files,
# never in this script.

param(
    [switch]$Deep,
    [switch]$NoPush,
    [string]$Config = ''
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

$hwDir = 'results/hardware'
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($cfg.hardware_dir) { $hwDir = [string]$cfg.hardware_dir }
}

if ($env:OS -ne 'Windows_NT') {
    Write-Host "[WARN] this collector is meant for the user's Windows machine." -ForegroundColor Yellow
}

# ------------------------------------------------------------------ helpers
function L ($t) { $script:md.Add([string]$t) }
function S ($v) { if ($null -eq $v) { '' } else { [string]$v } }
$md = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{}

$report.generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$report.host = $env:COMPUTERNAME
$report.user = $env:USERNAME
$report.powershell = $PSVersionTable.PSVersion.ToString()

# ------------------------------------------------------------------ os/cpu/ram
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

if ($os) {
    $report.os = [ordered]@{
        caption = S $os.Caption; version = S $os.Version
        build = S $os.BuildNumber;  last_boot = S $os.LastBootUpTime
    }
}
if ($cpu) {
    $report.cpu = [ordered]@{
        name = S $cpu.Name; cores = [int]$cpu.NumberOfCores
        threads = [int]$cpu.NumberOfLogicalProcessors; mhz = [int]$cpu.MaxClockSpeed
    }
}
if ($cs) {
    $report.ram = [ordered]@{
        total_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        free_gb  = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { $null }
    }
}

# ------------------------------------------------------------------ gpu
$gpus = @()
$nsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
$cudaDriver = ''
if ($nsmi) {
    $raw = & nvidia-smi 2>$null
    if (([string]::Join("`n", @($raw))) -match 'CUDA Version:\s*([\d.]+)') { $cudaDriver = $Matches[1] }
    $q = & nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>$null
    foreach ($line in @($q)) {
        if (-not $line) { continue }
        $p = @($line -split ',')
        $vram = (($p[2] -replace '[^0-9\.]', '') -as [double])
        $gpus += [ordered]@{
            name = $p[0].Trim(); driver = $p[1].Trim()
            vram_gb = [math]::Round($vram / 1024, 1)
            compute_cap = S $p[3].Trim(); cuda_driver = $cudaDriver
        }
    }
}
if ($gpus.Count -eq 0) {
    foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        $gpus += [ordered]@{
            name = S $v.Name; driver = S $v.DriverVersion
            vram_gb = [math]::Round($v.AdapterRAM / 1GB, 1)
            compute_cap = ''; cuda_driver = ''
            note = 'from Win32_VideoController (vram may under-report above 4GB)'
        }
    }
}
$report.gpus = $gpus

# ------------------------------------------------------------------ disks
$disks = @()
foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
    $disks += [ordered]@{
        drive = S $d.DeviceID
        total_gb = [math]::Round($d.Size / 1GB, 1); free_gb = [math]::Round($d.FreeSpace / 1GB, 1)
    }
}
$report.disks = $disks

# ------------------------------------------------------------------ python land
$py = [ordered]@{}
$g = Get-Command python -ErrorAction SilentlyContinue
if ($g) {
    $v = (& python -V 2>$null) -join ' '
    $py.global_python = ("{0}  ({1})" -f ($v.Trim()), (S $g.Source))
} else { $py.global_python = '(python not on PATH)' }
$py.current_env = if ($env:CONDA_DEFAULT_ENV) { $env:CONDA_DEFAULT_ENV } else { '(none)' }
$py.cuda_home   = if ($env:CUDA_HOME) { $env:CUDA_HOME } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { '' }

foreach ($tool in @('conda', 'mamba', 'micromamba')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = (& $tool --version 2>$null) -join ' '
        $py[$tool] = $ver.Trim()
    } else { $py[$tool] = '(not found)' }
}

$envs = @()
if ((Get-Command conda -ErrorAction SilentlyContinue)) {
    $lines = & conda env list 2>$null | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
    foreach ($line in @($lines)) {
        $t = @($line -split '\s+' | Where-Object { $_ })
        if ($t.Count -eq 0) { continue }
        $name = $t[0]
        $path = ''; if ($t[-1] -match '^[A-Za-z]:\\') { $path = $t[-1] }
        $e = [ordered]@{
            name = $name; path = $path; active = ($t -contains '*')
            python = ''; torch = ''; cuda_available = $null; torch_cuda = ''; gpu = ''
        }
        $pyExe = if ($path) { Join-Path $path 'python.exe' } else { '' }
        if ($pyExe -and (Test-Path -LiteralPath $pyExe)) {
            $e.python = ((& $pyExe -V 2>$null) -join ' ').Trim()
            if ($Deep) {
                $code = "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.device_count()); print(torch.version.cuda); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else '')"
                $to = & $pyExe -c $code 2>$null
                $tl = @($to) | Where-Object { $_ -and (($_ -join '') -notmatch 'Error|Traceback|Warning') }
                if ($tl.Count -ge 4) {
                    $e.torch = S $tl[0]
                    $e.cuda_available = ((S $tl[1]) -match 'True')
                    $e.torch_cuda = S $tl[3]
                    if ($tl.Count -ge 5 -and $tl[4]) { $e.gpu = S $tl[4] }
                } else { $e.torch = '(not installed)' }
            }
        }
        $envs += $e
    }
}
$py.envs = $envs
$report.python = $py

# ------------------------------------------------------------------ tools
$tools = [ordered]@{}
$tools.git = S (git --version 2>$null)
$tools.nvidia_smi = [bool]$nsmi
$report.tools = $tools

# ------------------------------------------------------------------ markdown
L '# Local machine hardware / environment report'
L ''
L ("- generated: {0} (local time)   host: {1}   user: {2}" -f $report.generated, $report.host, $report.user)
L '- produced by git-sync hardware.ps1; the agent reads it with agent-hardware.sh'
L ''
L '## OS / CPU / RAM'
if ($report.os)   { L ("- os: {0} (build {1})" -f $report.os.caption, $report.os.build) }
if ($report.cpu)  { L ("- cpu: {0} - {1} cores / {2} threads @ {3} MHz" -f $report.cpu.name, $report.cpu.cores, $report.cpu.threads, $report.cpu.mhz) }
if ($report.ram)  { L ("- ram: {0} GB total, {1} GB free" -f $report.ram.total_gb, $report.ram.free_gb) }
L ''
L '## GPU'
if ($gpus.Count -eq 0) { L '- (none detected)' }
foreach ($gpu in $gpus) {
    L ("- {0} - {1} GB vram, driver {2}, compute cap {3}, CUDA driver {4} {5}" -f `
       $gpu.name, $gpu.vram_gb, $gpu.driver, $gpu.compute_cap, $gpu.cuda_driver, (S $gpu.note))
}
L ''
L '## Disks'
foreach ($d in $disks) { L ("- {0} total {1} GB, free {2} GB" -f $d.drive, $d.total_gb, $d.free_gb) }
L ''
L '## Python / conda / mamba'
L ("- global python: {0}" -f $py.global_python)
L ("- current env: {0}   CUDA_HOME/CUDA_PATH: {1}" -f $py.current_env, $py.cuda_home)
L ("- conda: {0}   mamba: {1}   micromamba: {2}" -f $py.conda, $py.mamba, $py.micromamba)
foreach ($e in $envs) {
    $mark = if ($e.active) { '*' } else { ' ' }
    if ($Deep) {
        L ("- [{0}] {1}: python {2}, torch {3} (cuda {4}, built for cuda {5}) {6}" -f `
           $mark, $e.name, $e.python, $e.torch, $e.cuda_available, $e.torch_cuda, $e.gpu)
    } else {
        L ("- [{0}] {1}: python {2}" -f $mark, $e.name, $e.python)
    }
}
if (-not $Deep) { L '  (run with -Deep to also probe torch / CUDA per env)' }
L ''
L '## Tools'
L ("- git: {0}   nvidia-smi: {1}" -f $tools.git, $tools.nvidia_smi)
L ''

# ------------------------------------------------------------------ write
$dirAbs = Join-Path $repo ($hwDir -replace '/', '\')
$histDir = Join-Path $dirAbs 'history'
New-Item -ItemType Directory -Force -Path $histDir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')

[System.IO.File]::WriteAllText((Join-Path $dirAbs 'latest.json'), ($report | ConvertTo-Json -Depth 6), $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $dirAbs 'latest.md'), ($md -join "`r`n"), $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $histDir ($stamp + '.md')), ($md -join "`r`n"), $utf8NoBom)
Get-ChildItem -LiteralPath $histDir -Filter '*.md' | Sort-Object Name -Descending |
    Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "== report written to $hwDir (latest.md / latest.json + history snapshot)"
if ($report.cpu) { Write-Host ("   cpu: {0} ({1} cores / {2} threads)" -f $report.cpu.name, $report.cpu.cores, $report.cpu.threads) -ForegroundColor Gray }
if ($report.ram) { Write-Host ("   ram: {0} GB" -f $report.ram.total_gb) -ForegroundColor Gray }
foreach ($gpu in $gpus) { Write-Host ("   gpu: {0} ({1} GB)" -f $gpu.name, $gpu.vram_gb) -ForegroundColor Gray }
Write-Host ("   conda envs: {0}" -f $envs.Count) -ForegroundColor Gray

if ($NoPush) {
    Write-Host "== -NoPush given: files stay uncommitted. Run .\push.ps1 when ready." -ForegroundColor Yellow
} else {
    $push = Join-Path $repo 'push.ps1'
    if (-not (Test-Path -LiteralPath $push)) { $push = Join-Path $PSScriptRoot 'push.ps1' }
    if (Test-Path -LiteralPath $push) { & $push "hardware: update machine report" }
    else { Write-Host "[ERROR] push.ps1 not found - commit the report manually" -ForegroundColor Red }
}
