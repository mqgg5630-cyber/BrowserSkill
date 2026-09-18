# watch.ps1 - the local half of the auto-verification handshake.
#
# Registers a Windows scheduled task that polls the remote branch. When the
# agent requests a check (arena_state=awaiting_check, local_state=pending in
# the handshake file), the watcher automatically:
#     sync -> run the local check (check_cmd) -> write the log ->
#     push the verdict (passed/failed) back to the branch.
# The agent then reads the verdict with agent-check.sh --read and either
# accepts (loop ends) or fixes and requests another round.
#
# Usage (inside the repo folder):
#     .\watch.ps1 -Register              # once per machine: create the task
#     .\watch.ps1 -Register -Interval 10 # poll every 10 minutes instead of 2
#     .\watch.ps1 -Status                # is the watcher alive? mode, heartbeat, verdict
#     .\watch.ps1 -Test                  # run the task once NOW and verify it really ran
#     .\watch.ps1                        # one manual poll right now
#     .\watch.ps1 -Loop                  # poll forever in this console (what the task runs)
#     .\watch.ps1 -Pause / -Resume       # stop / restart polling (task stays)
#     .\watch.ps1 -Focus                 # this clone only: pause other git-sync-watch-*
#                                        # tasks + kill their loops (does NOT delete them)
#     .\watch.ps1 -RestoreParked         # resume the tasks -Focus paused
#     .\watch.ps1 -Register -KeepOthers  # register without pausing other conversations
#     .\watch.ps1 -Unregister            # remove the scheduled task
#     .\watch.ps1 -Register -Flash       # fallback launcher (brief flash per LOGON)
#     .\watch.ps1 -Register -Headless    # zero window via S4U (session 0, ADMIN console!)
#
# HANDS-FREE (v2.7.0) - the user no longer types .\sync.ps1 / .\push.ps1:
#   Config keys (skills/git-sync/sync.config.json):
#     hands_free / auto_pull / auto_push  (hands_free=true forces both on:
#       1) every idle poll runs sync.ps1  -> pull agent updates
#       2) if the worktree is dirty (minus excluded secrets / handshake) ->
#          silent push.ps1 -NoPrompt "local: auto <stamp>"
#       3) if a check is requested -> run check_cmd and push the verdict)
#   Agent side: agent-handsfree.sh waits for the watcher, evaluates
#   success_criteria.json, and --accept when both pass.
#
# WINDOW BEHAVIOUR - why v2.6.0 went "one process per logon":
#   A console app started by Task Scheduler ALWAYS gets a console window first;
#   '-WindowStyle Hidden' can only hide it afterwards. That is why the old design
#   flashed every poll (720 times a day at 2-minute polling) - user requirement
#   #1 is "no popup", so v2.6.0 registers ONE long-lived process per logon
#   (`watch.ps1 -Loop`) and lets it poll inside itself. Consequences:
#     * launcher mode (default): the task starts a tiny GUI-subsystem launcher
#       (compiled into %LOCALAPPDATA%\git-sync\, no admin, no VBScript) which
#       starts powershell with CreateNoWindow -> ZERO windows, ever;
#     * flash mode (fallback, automatic if the launcher fails its smoke test):
#       exactly ONE brief flash per logon/session, not one per poll;
#     * -Headless (S4U/session 0): zero windows too, but needs an ELEVATED
#       console to register and a credential store GCM can read from session 0
#       (gh auth setup-git is the easy one - see auth.ps1).
#   The task also gets a KeeperMin repetition trigger: if the long-lived process
#   ever dies, the next keeper tick starts it again (IgnoreNew means it does
#   nothing while the process is alive, so no extra windows).
#   Register always SMOKE-TESTS the launcher with a throwaway script, then
#   SELF-TESTS the registered task, and falls back to -Flash automatically if
#   the launcher does not run. After upgrading the skill, re-register
#   (.\watch.ps1 -Unregister ; .\watch.ps1 -Register) so the loop uses the new
#   code - a running loop keeps the code it started with.
#
# All of watch.ps1's own child processes inherit its hidden console, so they
# cannot flash either. Local state (heartbeat, log, launcher) lives in
# %LOCALAPPDATA%\git-sync\ - never in the repo, so nothing of it reaches git.
#
# NB: inside a double-quoted string write "${name}:" - a bare "$name:" parses as
# a drive-qualified variable name and kills the whole file at parse time.
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [int]$Interval = 2,
    [string]$Config = '',
    [switch]$Register,
    [switch]$Unregister,
    [switch]$Pause,
    [switch]$Resume,
    [switch]$Status,
    [switch]$Test,
    [switch]$Loop,
    [switch]$Headless,
    [switch]$Flash,
    [switch]$Focus,
    [switch]$RestoreParked,
    [switch]$KeepOthers,
    [int]$CheckTimeoutMin = 0,
    [int]$SelfTestSec = 90,
    [int]$KeeperMin = 10
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
$repoName = Split-Path -Leaf $repo

# ------------------------------------------------------------------- config
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

$cfg = $null
$Branch = ''; $Remote = 'origin'
$Handshake = 'results/status/handshake.json'
$CheckCmd  = 'powershell -NoProfile -ExecutionPolicy Bypass -File code/local_check.ps1'
$TimeoutMin = 30
$LockStaleMin = 45
$HandsFree = $false
$AutoPull = $false
$AutoPush = $false
$AutoPushPrefix = 'local: auto'
$AutoPushExclude = @('.env', '.env.*', '**/*.pem', '**/*.key', '**/credentials*', '**/*secret*', '**/*token*')
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($cfg.branch) { $Branch = [string]$cfg.branch }
    if ($cfg.remote) { $Remote = [string]$cfg.remote }
    if ($cfg.handshake) { $Handshake = [string]$cfg.handshake }
    if ($cfg.check_cmd) { $CheckCmd = [string]$cfg.check_cmd }
    if ($cfg.check_timeout_min) { $TimeoutMin = [int]$cfg.check_timeout_min }
    if ($cfg.lock_stale_min) { $LockStaleMin = [int]$cfg.lock_stale_min }
    if ($null -ne $cfg.hands_free) { $HandsFree = [bool]$cfg.hands_free }
    if ($null -ne $cfg.auto_pull)  { $AutoPull  = [bool]$cfg.auto_pull }
    if ($null -ne $cfg.auto_push)  { $AutoPush  = [bool]$cfg.auto_push }
    if ($cfg.auto_push_prefix) { $AutoPushPrefix = [string]$cfg.auto_push_prefix }
    if ($cfg.auto_push_exclude) {
        $AutoPushExclude = @($cfg.auto_push_exclude | ForEach-Object { [string]$_ })
    }
}
if (-not $Branch) { $Branch = (git rev-parse --abbrev-ref HEAD).Trim() }
if ($CheckTimeoutMin -gt 0) { $TimeoutMin = $CheckTimeoutMin }
if ($LockStaleMin -lt ($TimeoutMin + 15)) { $LockStaleMin = $TimeoutMin + 15 }

# hands_free is the master switch: when true, force both auto_pull and auto_push
if ($HandsFree) { $AutoPull = $true; $AutoPush = $true }

$taskName = 'git-sync-watch-' + $repoName
$skillVer = ''
$verFile = Join-Path $repo 'skills\git-sync\VERSION'
if (Test-Path -LiteralPath $verFile) { $skillVer = (Get-Content -LiteralPath $verFile -Raw).Trim() }

# local state (heartbeat / log / launcher) - outside the repo on purpose
$stateDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'git-sync' } else { Join-Path $env:TEMP 'git-sync' }
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$stateFile = Join-Path $stateDir ('watch-' + $repoName + '.json')
$hostLog   = Join-Path $stateDir ('watch-' + $repoName + '.log')
# the launcher goes into an ASCII-only directory: with a CJK user name
# (C:\Users\<CJK>\AppData\...) Process.Start on the freshly compiled exe
# failed with ERROR_BAD_EXE_FORMAT in the field report
$hostDir = ''
foreach ($cand in @((Join-Path $env:ProgramData 'git-sync'), (Join-Path $env:PUBLIC 'git-sync'), 'C:\git-sync')) {
    if (-not $cand) { continue }
    try {
        if (-not (Test-Path -LiteralPath $cand)) { New-Item -ItemType Directory -Force -Path $cand -ErrorAction Stop | Out-Null }
        if (Test-Path -LiteralPath $cand) { $hostDir = $cand; break }
    } catch { }
}
if (-not $hostDir) { $hostDir = $stateDir }
$hostExe   = Join-Path $hostDir ('watchhost-' + $repoName + '.exe')
$lockFile  = Join-Path $env:TEMP ($taskName + '.lock')
$loopFile  = Join-Path $stateDir ('watchloop-' + $repoName + '.pid')
# one machine-wide ledger of watchers paused by -Focus (so -RestoreParked
# can bring the previous conversation back without re-registering)
$parkFile  = Join-Path $stateDir 'parked.json'

# ------------------------------------------------------------- state helpers
function Get-State {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Set-State {
    param([hashtable]$Fields)
    $cur = Get-State
    $h = [ordered]@{}
    if ($cur) { foreach ($p in $cur.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    foreach ($k in $Fields.Keys) { $h[$k] = $Fields[$k] }
    try {
        $json = ($h | ConvertTo-Json -Depth 6)
        [System.IO.File]::WriteAllText($stateFile, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
function Add-Log {
    param([string]$Line)
    try {
        # keep the log bounded: rotate at 2 MB (a long-lived loop logs a lot)
        if (Test-Path -LiteralPath $hostLog) {
            $len = (Get-Item -LiteralPath $hostLog -ErrorAction SilentlyContinue).Length
            if ($len -gt 2MB) {
                $keep = @(Get-Content -LiteralPath $hostLog -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue)
                [System.IO.File]::WriteAllLines($hostLog, (@('(log rotated)') + $keep), (New-Object System.Text.UTF8Encoding($false)))
            }
        }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        [System.IO.File]::AppendAllText($hostLog, ("[$stamp] $Line`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
function Get-LogTail {
    param([int]$Lines = 12)
    if (-not (Test-Path -LiteralPath $hostLog)) { return @() }
    # Add-Log writes UTF-8 without BOM. Reading it back with the default
    # (ANSI/GBK on a Chinese Windows) turned a Chinese user name or note into
    # mojibake in "-Status", so the tail must be read as UTF-8 explicitly.
    return @(Get-Content -LiteralPath $hostLog -Tail $Lines -Encoding UTF8 -ErrorAction SilentlyContinue)
}

# ------------------------------------------------------- launcher (no window)
# GUI-subsystem launcher: Task Scheduler starts THIS exe, it starts powershell
# with CreateNoWindow, so Windows never allocates a console window at all.
# Extra arguments after the logfile are forwarded to the script (used for -Loop).
$hostSrc = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

class GitSyncWatchHost
{
    static StreamWriter log = null;

    static void Say(string s)
    {
        if (log == null || s == null) return;
        try { log.WriteLine(s); log.Flush(); } catch { }
    }

    static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("usage: watchhost <powershell.exe> <script.ps1> [workdir] [logfile] [extra args...]");
            return 2;
        }
        try
        {
            if (args.Length > 3 && args[3].Length > 0)
            {
                string dir = Path.GetDirectoryName(args[3]);
                if (dir != null && dir.Length > 0) Directory.CreateDirectory(dir);
                log = new StreamWriter(new FileStream(args[3], FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
                log.AutoFlush = true;
                Say("== host start " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            }
            ProcessStartInfo psi = new ProcessStartInfo(args[0]);
            string cmd = "-NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File \"" + args[1] + "\"";
            for (int i = 4; i < args.Length; i++) cmd += " " + args[i];
            psi.Arguments = cmd;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            if (args.Length > 2 && args[2].Length > 0) psi.WorkingDirectory = args[2];
            using (Process p = Process.Start(psi))
            {
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { Say(e.Data); };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { Say(e.Data); };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                Say("== host done exit=" + p.ExitCode.ToString() + " " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Say("== host FAILED: " + ex.GetType().Name + ": " + ex.Message);
            return 3;
        }
        finally
        {
            if (log != null) { try { log.Flush(); log.Dispose(); } catch { } }
        }
    }
}
'@

function Resolve-ToolPath {
    # map the first token of check_cmd to something Start-Process can execute
    param([string]$CmdLine)
    $first = ''
    $rest = ''
    if ($CmdLine -match '^\s*"([^"]+)"\s*(.*)$') { $first = $Matches[1]; $rest = $Matches[2] }
    elseif ($CmdLine -match '^\s*(\S+)\s*(.*)$') { $first = $Matches[1]; $rest = $Matches[2] }
    if (-not $first) { return @{ cmdLine = '' } }
    $path = ''
    if (Test-Path -LiteralPath $first) { $path = $first }
    if (-not $path) {
        $c = Get-Command $first -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) {
            foreach ($cand in @($c.Source, $c.Path, $c.Definition)) {
                if ($cand -and $cand -match '\.(exe|cmd|bat)$' -and (Test-Path -LiteralPath $cand)) { $path = $cand; break }
            }
        }
    }
    if (-not $path -and $first -match '^(powershell|pwsh)(\.exe)?$') {
        $ps = Get-PowerShellExe
        if (Test-Path -LiteralPath $ps) { $path = $ps }
    }
    if (-not $path -and $first -match '^(bash|sh)(\.exe)?$') {
        # prefer the bash that ships with the git we use: a WSL/bash.exe on PATH
        # cannot always read a Windows working directory
        $g = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g -and $g.Source) {
            $gitDir = Split-Path -Parent (Split-Path -Parent $g.Source)
            foreach ($cand in @((Join-Path $gitDir 'bin\bash.exe'), (Join-Path $gitDir 'usr\bin\bash.exe'))) {
                if (Test-Path -LiteralPath $cand) { $path = $cand; break }
            }
        }
        if (-not $path) {
            $c = Get-Command $first -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { $path = [string]$c.Source }
        }
        if (-not $path) {
            $sys = Join-Path $env:WINDIR 'System32\bash.exe'
            if (Test-Path -LiteralPath $sys) { $path = $sys }
        }
    }
    if (-not $path) { return @{ cmdLine = '' } }
    if ($rest) { return @{ cmdLine = ('"' + $path + '" ' + $rest) } }
    return @{ cmdLine = ('"' + $path + '"') }
}

function Get-PowerShellExe {
    # Prefer a 64-bit PowerShell, in this order:
    #   1. pwsh (PowerShell 7+) is respected exactly as it is - it is its own
    #      product and never WOW64-redirected in a way we should second-guess
    #   2. from a 32-BIT process, %WINDIR%\System32 is redirected by WOW64 to
    #      SysWOW64, so the 64-bit powershell.exe is only reachable through
    #      SysNative. A 32-bit watcher silently produced 32-bit children (and
    #      32-bit git-bash could not see some paths) - hence the explicit hop.
    #   3. System32 (already 64-bit when this process is 64-bit)
    #   4. only then fall back to whatever this process itself is
    $cand = $null
    try { $cand = (Get-Process -Id $PID).Path } catch { }
    if ($cand -and $cand -match 'pwsh\.exe$') { return $cand }
    $is32 = $false
    try { $is32 = -not [Environment]::Is64BitProcess } catch { }
    if ($is32 -and $env:WINDIR) {
        $native = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $native) { return $native }
    }
    if ($env:WINDIR) {
        $sys = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $sys) { return $sys }
    }
    if ($cand -and $cand -match 'powershell\.exe$') { return $cand }
    return 'powershell.exe'
}

function New-WatchHost {
    # compile the launcher; returns the exe path, or '' when compilation fails
    $exe = $hostExe
    $cs  = [System.IO.Path]::ChangeExtension($hostExe, '.cs')
    $tmp = $hostExe + '.new'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $ok = $false
    try {
        Add-Type -TypeDefinition $hostSrc -OutputAssembly $tmp -OutputType WindowsApplication -ErrorAction Stop
        $ok = $true
    } catch {
        $ok = $false
    }
    if (-not $ok) {
        # fallback: call the C# compiler of .NET Framework directly
        try {
            [System.IO.File]::WriteAllText($cs, $hostSrc, (New-Object System.Text.UTF8Encoding($false)))
            $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
            if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
            if (Test-Path -LiteralPath $csc) {
                & $csc /nologo /target:winexe /out:$tmp $cs 2>&1 | Out-Null
                if (Test-Path -LiteralPath $tmp) { $ok = $true }
            }
        } catch { $ok = $false }
    }
    if (-not $ok) { return '' }
    # sanity: a real Windows executable starts with "MZ" - if it does not, the
    # compiler output was quarantined/blocked (antivirus) and Process.Start will
    # report "%1 is not a valid Win32 application"
    try {
        $fs = [System.IO.File]::OpenRead($tmp)
        $head = New-Object byte[] 2
        $null = $fs.Read($head, 0, 2)
        $fs.Close()
        if (-not ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)) {
            Add-Log "launcher exe is not a PE file (MZ missing) - antivirus may have rewritten it: $tmp"
            return ''
        }
    } catch {
        Add-Log "could not verify the launcher exe: $($_.Exception.Message)"
        return ''
    }
    try {
        Move-Item -LiteralPath $tmp -Destination $exe -Force -ErrorAction Stop
        return $exe
    } catch {
        $alt = $hostExe -replace '\.exe$', ('-v' + (Get-Date -Format 'HHmmss') + '.exe')
        try { Move-Item -LiteralPath $tmp -Destination $alt -Force -ErrorAction Stop; return $alt } catch { return '' }
    }
}

function Test-WatchHost {
    # run the launcher ONCE on a throwaway script and see whether the marker
    # file appears. This isolates "the launcher works" from "Task Scheduler
    # starts it" - the two can fail independently and used to look the same.
    param([string]$Exe, [string]$PsExe)
    if (-not $Exe) { return $false }
    $marker = Join-Path $stateDir ('smoke-' + $repoName + '.txt')
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    $smokePs = Join-Path $stateDir ('smoke-' + $repoName + '.ps1')
    # BOM on purpose: PS 5.1 reads a BOM-less file as ANSI and the marker path
    # may contain non-ASCII characters (e.g. a user name)
    $line = "[System.IO.File]::WriteAllText('" + $marker + "', (Get-Date).ToString('o'))"
    [System.IO.File]::WriteAllText($smokePs, $line, (New-Object System.Text.UTF8Encoding($true)))
    $markerB = Join-Path $stateDir ('hostmark-' + $repoName + '.txt')
    Remove-Item -LiteralPath $markerB -Force -ErrorAction SilentlyContinue
    $p = $null
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList @($PsExe, $smokePs, $repo, $markerB) -NoNewWindow -PassThru
    } catch {
        Add-Log "launcher smoke test could not start: $($_.Exception.Message)"
        Add-Log "   exe: $Exe ($([System.IO.File]::Exists($Exe)))  size: $((Get-Item -LiteralPath $Exe -ErrorAction SilentlyContinue).Length)"
        Add-Log '   "%1 is not a valid Win32 application" here means the file was blocked by antivirus'
        Add-Log '   or the path is not usable - see the launcher path in the message above'
        return $false
    }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $marker) {
            try { $p.Kill() } catch { }
            return $true
        }
        if ($p -and $p.HasExited -and -not (Test-Path -LiteralPath $marker)) { break }
        Start-Sleep -Milliseconds 700
    }
    try { if ($p -and -not $p.HasExited) { $p.Kill() } } catch { }
    Add-Log "launcher smoke test FAILED (no marker) - see the host log lines above"
    return $false
}

function Get-LoopPid {
    if (-not (Test-Path -LiteralPath $loopFile)) { return 0 }
    try {
        $t = (Get-Content -LiteralPath $loopFile -Raw -ErrorAction SilentlyContinue) -replace '[^0-9]', ''
        if ($t) { return [int]$t }
    } catch { }
    return 0
}
function Test-VisibleConsole {
    # true when this process owns a console window the user can see
    try {
        if (-not ('GitSyncWin' -as [type])) {
            Add-Type -Namespace GitSyncWin -Name Native -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@
        }
        $h = [GitSyncWin.Native]::GetConsoleWindow()
        if ($h -eq [System.IntPtr]::Zero) { return $false }
        return [GitSyncWin.Native]::IsWindowVisible($h)
    } catch { return $true }
}

function Get-WatchLoops {
    # every powershell process running a clone's watch.ps1 -Loop. Needed
    # because a loop started by an older version carries no pid file, so it
    # cannot be found by pid alone - and a leftover loop keeps polling (and, if
    # it owns a console, keeps printing in it = "the console looks stuck",
    # field report 2026-09-16). -Name defaults to THIS clone; -Focus uses it
    # for every other clone too.
    param([string]$Name = $repoName)
    $out = @()
    if (-not $Name) { return $out }
    try {
        $mine = $PID
        $q = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop
        foreach ($proc in $q) {
            $cl = [string]$proc.CommandLine
            if (-not $cl) { continue }
            if ($cl -notmatch '\-Loop\b') { continue }
            # match the clone folder as a path segment (...\Name\watch.ps1)
            # so git-pull-arena does not also kill git-pull-arena-s2
            if ($cl -notmatch ([regex]::Escape($Name) + '[\\/]watch\.ps1')) { continue }
            if ($proc.ProcessId -eq $mine) { continue }
            $out += [pscustomobject]@{ Pid = $proc.ProcessId; Command = $cl }
        }
    } catch { }
    return $out
}

function Stop-StaleLoops {
    # stop every other loop of this repo (any version) - called at loop start,
    # and by -Pause / -Unregister
    $killed = 0
    foreach ($l in (Get-WatchLoops)) {
        try {
            Stop-Process -Id $l.Pid -Force -ErrorAction Stop
            Add-Log ("stopped a stale loop (pid {0}) - older version or leftover" -f $l.Pid)
            $killed++
        } catch {
            Add-Log ("could not stop stale loop pid {0}: {1}" -f $l.Pid, $_.Exception.Message)
        }
    }
    return $killed
}

function Get-TaskInfo {
    $t = $null
    try { $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { return $null }
    $i = $null
    try { $i = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop } catch { }
    return @{ task = $t; info = $i }
}

function Get-TaskMode {
    param($Task)
    if (-not $Task) { return 'unknown' }
    $exec = ''
    $argstr = ''
    try { $exec = [string]$Task.Actions[0].Execute } catch { }
    try { $argstr = [string]$Task.Actions[0].Arguments } catch { }
    $logon = ''
    try { $logon = [string]$Task.Principal.LogonType } catch { }
    if ($logon -eq 'S4U' -or $logon -eq 'Password') { return 'headless (session 0)' }
    if ($exec -match 'watchhost') {
        if ($argstr -match '-Loop') { return 'zero-window loop (launcher exe)' }
        return 'zero-window (launcher exe)'
    }
    if ($exec -match 'powershell' -or $exec -match 'pwsh') {
        if ($argstr -match '-Loop') { return 'loop (one flash per logon)' }
        return 'flash (hidden powershell)'
    }
    return ("other: $exec $argstr")
}

function Start-TaskNow {
    try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop; return $true } catch { }
    & schtasks /Run /TN $taskName 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Stop-TaskNow {
    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop; return $true } catch { }
    & schtasks /End /TN $taskName 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Wait-ForRun {
    param([datetime]$After, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $s = Get-State
        if ($s -and $s.last_run) {
            try { if ([datetime]$s.last_run -ge $After) { return $s } } catch { }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

# Scheduled-task result codes that are NORMAL for a long-lived loop. Anything
# outside this list is worth a warning; anything inside it is not a failure.
#   0            completed
#   267009       0x41301  the task is running right now (the loop never exits)
#   267011       0x41303  the task has never run yet (just registered)
#   267014       0x41306  terminated by the user (-Pause / -Unregister)
#   2147946720   0x800710E0 the operator or administrator has refused the
#                request - i.e. an instance is already running, which is
#                exactly what the keeper trigger produces every 10 min
$script:NormalTaskResults = @(0, 267009, 267011, 267014, 2147946720)

function Get-TaskResultNote {
    param($Code)
    $n = 0
    try { $n = [int64]$Code } catch { return '' }
    switch ($n) {
        0          { return 'completed' }
        267009     { return 'still RUNNING (0x41301) - normal, the loop never exits' }
        267011     { return 'has never run yet (0x41303) - just registered' }
        267014     { return 'terminated by the user (0x41306) - -Pause / -Unregister' }
        2147946720 { return 'launch refused (0x800710E0) - an instance is already running; normal with the keeper trigger' }
        default    { return '' }
    }
}

function Test-TaskResultNormal {
    param($Code)
    $n = -1
    try { $n = [int64]$Code } catch { return $false }
    return ($script:NormalTaskResults -contains $n)
}

function Test-ProxyHint {
    $gp = ''
    try { $gp = ((git config --get http.proxy 2>$null | Out-String).Trim()) } catch { }
    if (-not $gp) { try { $gp = ((git config --get https.proxy 2>$null | Out-String).Trim()) } catch { } }
    if ($gp -and -not $env:HTTPS_PROXY) {
        Write-Host ("   hint: git uses proxy $gp but HTTPS_PROXY is not set - gh will NOT use it.") -ForegroundColor Yellow
        Write-Host '         copy this line into a NEW cmd/PowerShell window, then reopen the window:' -ForegroundColor Yellow
        Write-Host ('         setx HTTPS_PROXY "' + $gp + '"') -ForegroundColor Yellow
    }
}

function Show-TaskDiagnostics {
    $ti = Get-TaskInfo
    if ($ti -and $ti.info) {
        $note = Get-TaskResultNote $ti.info.LastTaskResult
        $shown = [string]$ti.info.LastTaskResult
        if ($note) { $shown = $shown + ' (' + $note + ')' }
        Write-Host ("     task: last run {0} | result {1} | next {2}" -f $ti.info.LastRunTime, $shown, $ti.info.NextRunTime) -ForegroundColor DarkGray
    }
    if (Test-Path -LiteralPath $hostLog) {
        Write-Host "     host log (tail):" -ForegroundColor DarkGray
        Get-LogTail 12 | ForEach-Object { Write-Host ("       " + $_) -ForegroundColor DarkGray }
    }
}

function Get-AllWatchTasks {
    $out = @()
    try { $out = @(Get-ScheduledTask -TaskName 'git-sync-watch-*' -ErrorAction SilentlyContinue) } catch { }
    if (-not $out) { return @() }
    return @($out)
}

function Stop-RepoLoops {
    # stop the long-lived loop of ANY clone (pid file + leftover processes)
    param([string]$Name)
    $killed = 0
    if (-not $Name) { return 0 }
    $pf = Join-Path $stateDir ('watchloop-' + $Name + '.pid')
    if (Test-Path -LiteralPath $pf) {
        $lp = 0
        try {
            $raw = (Get-Content -LiteralPath $pf -Raw -ErrorAction SilentlyContinue) -replace '[^0-9]', ''
            if ($raw) { $lp = [int]$raw }
        } catch { }
        if ($lp -gt 0) {
            try { Stop-Process -Id $lp -Force -ErrorAction Stop; $killed++ } catch { }
        }
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
    }
    foreach ($l in (Get-WatchLoops -Name $Name)) {
        try { Stop-Process -Id $l.Pid -Force -ErrorAction Stop; $killed++ } catch { }
    }
    return $killed
}

function Get-ParkLedger {
    if (-not (Test-Path -LiteralPath $parkFile)) {
        return [pscustomobject]@{ updated = ''; last_focus = ''; items = @() }
    }
    try {
        return (Get-Content -LiteralPath $parkFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{ updated = ''; last_focus = ''; items = @() }
    }
}

function Save-ParkLedger {
    param($Ledger)
    try {
        $json = ($Ledger | ConvertTo-Json -Depth 6)
        [System.IO.File]::WriteAllText($parkFile, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Invoke-ParkOthers {
    # pause every OTHER git-sync-watch-* task and kill its loop. Does NOT
    # Unregister: the task stays so -RestoreParked / -Focus on that clone
    # can bring it back. Already-Disabled tasks are left alone (frozen).
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $did = @()
    foreach ($t in (Get-AllWatchTasks)) {
        $tn = [string]$t.TaskName
        if (-not $tn) { continue }
        if ($tn -eq $taskName) { continue }
        $st = ''
        try { $st = [string]$t.State } catch { }
        if ($st -eq 'Disabled') { continue }
        $other = $tn
        if ($tn.Length -gt 16 -and $tn.Substring(0, 16) -eq 'git-sync-watch-') {
            $other = $tn.Substring(16)
        }
        try { Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch { }
        $n = Stop-RepoLoops $other
        try { Disable-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch { }
        $did += [pscustomobject]@{
            task = $tn; repo = $other; state_before = $st
            loops_stopped = $n; parked_at = $now; parked_by = $taskName
        }
        Add-Log ("parked other watcher: $tn (was $st, stopped $n loop(s))")
    }
    $ledger = Get-ParkLedger
    $byName = @{}
    if ($ledger.items) {
        foreach ($it in @($ledger.items)) {
            $k = [string]$it.task
            if ($k -and $k -ne $taskName) { $byName[$k] = $it }
        }
    }
    foreach ($it in $did) { $byName[$it.task] = $it }
    $merged = @()
    foreach ($k in $byName.Keys) { $merged += $byName[$k] }
    Save-ParkLedger ([ordered]@{ updated = $now; last_focus = $taskName; items = $merged })
    return $did
}

function Invoke-RestoreParked {
    $ledger = Get-ParkLedger
    $items = @()
    if ($ledger.items) { $items = @($ledger.items) }
    $n = 0
    foreach ($it in $items) {
        $tn = [string]$it.task
        if (-not $tn) { continue }
        try { Enable-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch { }
        try { Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch { }
        Add-Log ("restored parked watcher: $tn")
        $n++
    }
    Save-ParkLedger ([ordered]@{
        updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        last_focus = ''
        items = @()
    })
    return $n
}

function Invoke-Focus {
    # this clone is the active conversation: park every other watcher, then
    # make sure THIS task is enabled and running
    if (Get-TaskInfo) {
        try { Enable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
        $null = Start-TaskNow
    }
    return (Invoke-ParkOthers)
}

# ----------------------------------------------------------- pause / resume
if ($Focus) {
    $parked = @(Invoke-Focus)
    Write-Host ("== focus : {0}  (this conversation is the active watcher)" -f $taskName) -ForegroundColor Green
    if (-not (Get-TaskInfo)) {
        Write-Host "   [warn] this clone has no scheduled task yet - run .\\watch.ps1 -Register" -ForegroundColor Yellow
    }
    if ($parked.Count -eq 0) {
        Write-Host "   no other git-sync-watch-* tasks were running"
    } else {
        Write-Host ("   parked {0} other conversation(s) (task kept, loop stopped):" -f $parked.Count)
        foreach ($it in $parked) {
            Write-Host ("     {0}  (was {1}, stopped {2} loop(s))" -f $it.task, $it.state_before, $it.loops_stopped)
        }
        Write-Host "   come back later with:  cd <that-clone> ; .\\watch.ps1 -Focus"
        Write-Host "   or resume them all:    .\\watch.ps1 -RestoreParked"
    }
    exit 0
}
if ($RestoreParked) {
    $n = Invoke-RestoreParked
    if ($n -eq 0) {
        Write-Host "== nothing parked (ledger empty) - no other watchers to restore"
    } else {
        Write-Host ("== restored {0} parked watcher(s) - they poll again" -f $n) -ForegroundColor Green
    }
    exit 0
}
if ($Pause) {
    $null = Stop-TaskNow
    $lp = Get-LoopPid
    if ($lp -gt 0 -and (Get-Process -Id $lp -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $lp -Force -ErrorAction SilentlyContinue
        Write-Host "   (stopped the running loop, pid $lp)"
    }
    $n = Stop-StaleLoops
    if ($n -gt 0) { Write-Host "   (stopped $n leftover loop process(es) from an older version)" }
    Remove-Item -LiteralPath $loopFile -Force -ErrorAction SilentlyContinue
    $null = Disable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($?) { Write-Host "== paused : $taskName  (stopped + disabled until .\watch.ps1 -Resume)" -ForegroundColor Green }
    else { Write-Host "[ERROR] task not found: $taskName (nothing to pause)" -ForegroundColor Red }
    exit 0
}
if ($Resume) {
    $null = Enable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($?) {
        $null = Start-TaskNow
        Write-Host "== resumed: $taskName  (polling again)" -ForegroundColor Green
    } else { Write-Host "[ERROR] task not found: $taskName - run .\watch.ps1 -Register first" -ForegroundColor Red }
    exit 0
}

# ------------------------------------------------------------------- status
if ($Status) {
    $ti = Get-TaskInfo
    $st = Get-State
    Write-Host "== watcher status" -ForegroundColor Cyan
    Test-ProxyHint
    Write-Host ("   repo        : {0}" -f $repo)
    Write-Host ("   branch      : {0} (remote {1})" -f $Branch, $Remote)
    Write-Host ("   task        : {0}" -f $taskName)
    Write-Host ("   skill       : {0}" -f $(if ($skillVer) { "v$skillVer" } else { '(unknown)' }))
    Write-Host ("   hands-free  : master={0} auto_pull={1} auto_push={2}" -f $HandsFree, $AutoPull, $AutoPush)
    Write-Host ("   state dir   : {0}" -f $stateDir)
    if (-not $ti) {
        Write-Host "   scheduled   : NOT REGISTERED - run .\watch.ps1 -Register" -ForegroundColor Red
    } else {
        $state = ''
        try { $state = [string]$ti.task.State } catch { }
        Write-Host ("   scheduled   : {0} | mode: {1}" -f $state, (Get-TaskMode $ti.task))
        if ($ti.info) {
            $note = Get-TaskResultNote $ti.info.LastTaskResult
            $shown = [string]$ti.info.LastTaskResult
            if ($note) { $shown = $shown + ' = ' + $note }
            Write-Host ("   last run    : {0} | schedule result: {1}" -f $ti.info.LastRunTime, $shown)
            if (-not (Test-TaskResultNormal $ti.info.LastTaskResult)) {
                Write-Host "                 ^ not one of the normal codes (0 / 267009 / 267011 / 267014 / 2147946720)" -ForegroundColor Yellow
                Write-Host "                   read the host log tail below before re-registering" -ForegroundColor Yellow
            }
            Write-Host ("   next keeper : {0}" -f $ti.info.NextRunTime)
        }
    }
    if ($st) {
        Write-Host ""
        Write-Host "   heartbeat   :" -ForegroundColor Cyan
        foreach ($p in $st.PSObject.Properties) { Write-Host ("     {0,-14} {1}" -f $p.Name, $p.Value) }
        $alive = 'unknown'
        if ($st.pid) {
            if (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue) { $alive = "yes (pid $($st.pid) is running)" }
            else { $alive = "no (pid $($st.pid) exited)" }
        }
        $stale = Get-WatchLoops
        if ($stale.Count -gt 0) {
            Write-Host ("   other loops : {0} leftover loop process(es) still polling: {1}" -f $stale.Count, (($stale | ForEach-Object { $_.Pid }) -join ', ')) -ForegroundColor Yellow
            Write-Host "                 clean up with: .\watch.ps1 -Unregister ; .\watch.ps1 -Register" -ForegroundColor Yellow
        }
        $lpShown = Get-LoopPid
        if ($lpShown -gt 0) {
            $lpAlive = [bool](Get-Process -Id $lpShown -ErrorAction SilentlyContinue)
            Write-Host ("   loop process: pid {0} {1}" -f $lpShown, $(if ($lpAlive) { '(running)' } else { '(gone - the keeper tick restarts it within 10 min)' }))
        }
        if ($st.last_run) {
            try {
                $age = [int]((Get-Date) - [datetime]$st.last_run).TotalMinutes
                $limit = [int]($Interval * 2 + 2)
                $verdict = if ($age -le $limit) { 'fresh' } else { "STALE (${age} min > ${limit}) - the loop may be dead" }
                Write-Host ("   loop alive  : {0} | heartbeat age: {1} min ({2})" -f $alive, $age, $verdict) -ForegroundColor $(if ($age -le $limit) { 'Green' } else { 'Yellow' })
            } catch { Write-Host ("   loop alive  : {0}" -f $alive) }
        } else {
            Write-Host ("   loop alive  : {0}" -f $alive)
        }
    } else {
        Write-Host "   heartbeat   : (none yet - the task has never completed a poll)" -ForegroundColor Yellow
    }
    $logs = @(Get-ChildItem -Path (Join-Path $repo 'results\status') -Filter 'check_r*.txt' -ErrorAction SilentlyContinue |
              Sort-Object { try { [int]([regex]::Match($_.Name, 'check_r(\d+)').Groups[1].Value) } catch { 0 } } | Select-Object -Last 1)
    if ($logs.Count -gt 0) {
        Write-Host ""
        Write-Host ("   last check  : {0}" -f $logs[0].FullName) -ForegroundColor Cyan
        Get-Content -LiteralPath $logs[0].FullName -Tail 8 -Encoding UTF8 | ForEach-Object { Write-Host ("     " + $_) }
    }
    $others = @()
    foreach ($ot in (Get-AllWatchTasks)) {
        if ([string]$ot.TaskName -eq $taskName) { continue }
        $others += $ot
    }
    if ($others.Count -gt 0) {
        Write-Host ""
        Write-Host "   other tasks :" -ForegroundColor Cyan
        foreach ($ot in $others) {
            $ost = ''
            try { $ost = [string]$ot.State } catch { }
            Write-Host ("     {0}  [{1}]" -f $ot.TaskName, $ost)
        }
        Write-Host "                 switch: .\watch.ps1 -Focus    restore all: .\watch.ps1 -RestoreParked" -ForegroundColor DarkGray
    }
    if (Test-Path -LiteralPath $parkFile) {
        try {
            $pl = Get-ParkLedger
            $pc = 0
            if ($pl.items) { $pc = @($pl.items).Count }
            if ($pc -gt 0) {
                Write-Host ("   parked      : {0} task(s) by {1} at {2} - .\watch.ps1 -RestoreParked" -f $pc, $pl.last_focus, $pl.updated) -ForegroundColor Yellow
            }
        } catch { }
    }
    Write-Host ""
    Write-Host "   host log    : $hostLog (tail)" -ForegroundColor Cyan
    Get-LogTail 12 | ForEach-Object { Write-Host ("     " + $_) }
    exit 0
}

# --------------------------------------------------------------------- test
if ($Test) {
    $ti = Get-TaskInfo
    if (-not $ti) { Write-Host "[ERROR] not registered yet - run .\watch.ps1 -Register" -ForegroundColor Red; exit 1 }
    # a long-lived loop is meant to keep running: if it is alive and its
    # heartbeat is fresh, that IS the proof - do not wait for a new launch
    $st0 = Get-State
    $loopPid0 = Get-LoopPid
    $loopAlive0 = ($loopPid0 -gt 0 -and (Get-Process -Id $loopPid0 -ErrorAction SilentlyContinue))
    if ($loopAlive0 -and $st0 -and $st0.last_run) {
        try {
            $age0 = [int]((Get-Date) - [datetime]$st0.last_run).TotalMinutes
            if ($age0 -le ($Interval * 2 + 2)) {
                Write-Host ("== OK: the watcher loop is already running (pid {0}, heartbeat {1}, {2} min ago)" -f $loopPid0, $st0.last_run, $age0) -ForegroundColor Green
                exit 0
            }
        } catch { }
    }
    Write-Host "== running the scheduled task once (proves the launcher really runs) ..." -ForegroundColor Cyan
    $before = Get-Date
    if (-not (Start-TaskNow)) { Write-Host "[ERROR] could not start the task" -ForegroundColor Red; exit 1 }
    $s = Wait-ForRun -After $before -TimeoutSec $SelfTestSec
    if ($s) {
        Write-Host ("== OK: the watcher ran ({0}) - last action: {1}" -f $s.last_run, $s.last_action) -ForegroundColor Green
        exit 0
    }
    Write-Host "== FAILED: no heartbeat appeared - the task did not really run." -ForegroundColor Red
    Show-TaskDiagnostics
    Write-Host "   re-register with the fallback launcher:  .\watch.ps1 -Register -Flash" -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------------------ register task
if ($Register -or $Unregister) {
    if ($Unregister) {
        $null = Stop-TaskNow
        $lp = Get-LoopPid
        if ($lp -gt 0 -and (Get-Process -Id $lp -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $lp -Force -ErrorAction SilentlyContinue
            Write-Host "   (stopped the running loop, pid $lp)"
        }
        $n = Stop-StaleLoops
        if ($n -gt 0) { Write-Host "   (stopped $n leftover loop process(es) from an older version)" }
        Remove-Item -LiteralPath $loopFile -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($?) { Write-Host "== removed scheduled task: $taskName" -ForegroundColor Green }
        else { schtasks /Delete /TN $taskName /F 2>$null; Write-Host "== removed (schtasks): $taskName" }
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
        Write-Host "   (the launcher and heartbeat in $stateDir were kept)"
        exit 0
    }

    # stop a previous instance first: a running (old-code) loop would otherwise
    # survive the re-registration and keep polling with stale scripts
    if (Get-TaskInfo) { $null = Stop-TaskNow; Start-Sleep -Seconds 2; Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }

    $psExe = Get-PowerShellExe
    $taskScript = Join-Path $repo 'watch.ps1'
    if (-not (Test-Path -LiteralPath $taskScript)) { $taskScript = $PSCommandPath }

    # environment preflight: the task inherits the USER environment, which is
    # not always the PATH this console has (custom git installs, conda tools)
    $gitExe = ''
    $gcmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gcmd) {
        $gitExe = [string]$gcmd.Source
        if (-not $gitExe) { $gitExe = [string]$gcmd.Path }
        if (-not $gitExe) { $gitExe = [string]$gcmd.Definition }
    }
    if (-not $gitExe) {
        Write-Host "[ERROR] git is not on PATH in this console - the watcher will not find it." -ForegroundColor Red
        Write-Host "        add git to the PATH of your USER account and register again." -ForegroundColor Yellow
        exit 1
    }
    $bashExe = ''
    $bcmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($bcmd) {
        $bashExe = [string]$bcmd.Source
        if (-not $bashExe) { $bashExe = [string]$bcmd.Path }
        if (-not $bashExe) { $bashExe = [string]$bcmd.Definition }
    }
    $gitProxy = ''
    try { $gitProxy = ((git config --get http.proxy 2>$null | Out-String).Trim()) } catch { }
    if (-not $gitProxy) { try { $gitProxy = ((git config --get https.proxy 2>$null | Out-String).Trim()) } catch { } }
    Write-Host "== environment for the task:"
    Write-Host ("   git  : {0}" -f $gitExe)
    Write-Host ("   bash : {0}" -f $(if ($bashExe) { $bashExe } else { '(missing - the repo gate needs it)' }))
    Write-Host ("   ps   : {0}" -f $psExe)
    Write-Host ("   proxy: {0}" -f $(if ($gitProxy) { "$gitProxy (git config http.proxy)" } else { '(none in git config - gh/other tools need HTTPS_PROXY)' }))

    # ---- decide the launch mode -------------------------------------------
    $mode = ''
    $exe  = ''
    $arg  = ''
    if ($Headless) {
        # S4U registration needs an elevated console (0x80070005 otherwise) -
        # say so BEFORE failing, with the exact command to copy
        $isAdmin = $false
        try {
            $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { }
        if (-not $isAdmin) {
            Write-Host "[ERROR] -Headless (S4U / session 0) needs an ELEVATED PowerShell." -ForegroundColor Red
            Write-Host "        open 'Windows PowerShell' with 'Run as administrator' and run:" -ForegroundColor Yellow
            Write-Host "          cd `"$repo`"" -ForegroundColor Yellow
            Write-Host "          .\watch.ps1 -Unregister ; .\watch.ps1 -Register -Headless" -ForegroundColor Yellow
            Write-Host "        (it also needs a session-0 readable credential: run .\auth.ps1 -GhLogin first)" -ForegroundColor Yellow
            exit 1
        }
        $mode = 'headless'
        $exe = $psExe
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Loop' -f $taskScript
    } else {
        if (-not $Flash) {
            Write-Host "== building the zero-window launcher (no admin needed) ..." -ForegroundColor Cyan
            $hostPath = New-WatchHost
            if ($hostPath) {
                Write-Host ("   launcher: {0}" -f $hostPath)
                Write-Host ("   (ASCII-only path on purpose - a CJK user name breaks Process.Start)" -f $hostPath)
                Write-Host "== smoke-testing the launcher (throwaway script, 60s max) ..." -ForegroundColor Cyan
                if (Test-WatchHost -Exe $hostPath -PsExe $psExe) {
                    Write-Host "   launcher works - the task will run with ZERO windows" -ForegroundColor Green
                    $mode = 'zero-window'
                    $exe = $hostPath
                    $arg = '"{0}" "{1}" "{2}" "{3}" -Loop' -f $psExe, $taskScript, $repo, $hostLog
                } else {
                    Write-Host "   [warn] launcher did not produce its marker - falling back to -Flash" -ForegroundColor Yellow
                    Write-Host "          host log (tail) - this says WHY:" -ForegroundColor DarkGray
                    Get-LogTail 15 | ForEach-Object { Write-Host ("            " + $_) -ForegroundColor DarkGray }
                    Write-Host "          send the lines above to the agent if you want zero-window mode" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "   [warn] could not compile the launcher - falling back to -Flash" -ForegroundColor Yellow
            }
        }
        if (-not $mode) {
            # fallback: one brief flash per LOGON (not per poll - the task runs
            # the whole -Loop in that one process)
            $mode = 'flash'
            $exe = $psExe
            $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Loop' -f $taskScript
        }
    }

    $desc = "git-sync v$skillVer watcher | mode=$mode | loop every ${Interval}m | $repo"
    $registered = $false
    try {
        $action  = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $repo
        $triggers = @()
        try {
            $triggers += New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME -ErrorAction Stop
        } catch {
            $triggers += New-ScheduledTaskTrigger -AtLogOn -ErrorAction SilentlyContinue
        }
        # keeper tick: restarts the loop if it ever died (IgnoreNew = a no-op
        # while the loop is alive, so it costs no window and no work)
        $triggers += New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                        -RepetitionInterval (New-TimeSpan -Minutes $KeeperMin) `
                        -RepetitionDuration (New-TimeSpan -Days 3650)
        # the loop is meant to live forever: no execution time limit
        $settings = $null
        try {
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ErrorAction Stop
        } catch { $settings = $null }
        $regArgs = @{ TaskName = $taskName; Action = $action; Trigger = $triggers; Description = $desc; Force = $true }
        if ($settings) { $regArgs['Settings'] = $settings }
        if ($mode -eq 'headless') {
            $regArgs['Principal'] = (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited)
        }
        Register-ScheduledTask @regArgs | Out-Null
        $registered = $true
    } catch {
        Write-Host "   [warn] Register-ScheduledTask failed: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($mode -eq 'headless') {
            Write-Host "          S4U needs an ELEVATED PowerShell (access denied 0x80070005 otherwise)." -ForegroundColor Yellow
        } else {
            Write-Host "          trying schtasks.exe instead ..." -ForegroundColor Yellow
            schtasks /Create /F /TN $taskName /SC MINUTE /MO $KeeperMin /TR "`"$exe`" $arg" | Out-Null
            if ($LASTEXITCODE -eq 0) { $registered = $true }
        }
    }

    if (-not $registered) {
        Write-Host ""
        Write-Host "[ERROR] could not register the watcher." -ForegroundColor Red
        Write-Host "        run .\watch.ps1 -Register -Flash   (visible flash once per logon)" -ForegroundColor Yellow
        Write-Host "        output above + '$hostLog' say what failed." -ForegroundColor Yellow
        exit 1
    }

    Set-State @{ mode = $mode; interval = $Interval; repo = $repo; branch = $Branch; remote = $Remote;
                 skill = $skillVer; task = $taskName; git = $gitExe; bash = $bashExe; powershell = $psExe; proxy = $gitProxy;
                 launcher = $(if ($mode -eq 'zero-window') { $exe } else { '' });
                 registered = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    Add-Log "registered: mode=$mode interval=${Interval}m keeper=${KeeperMin}m skill=v$skillVer git=$gitExe bash=$bashExe proxy=$gitProxy"
    Write-Host "== registered: $taskName (mode=$mode, loop every $Interval min, keeper tick every $KeeperMin min)" -ForegroundColor Green

    # ---- self-test: start it now and wait for a real heartbeat -------------
    Write-Host "== self-test: starting the task and waiting for a heartbeat (max ${SelfTestSec}s) ..." -ForegroundColor Cyan
    $before = Get-Date
    if (Start-TaskNow) {
        $s = Wait-ForRun -After $before -TimeoutSec $SelfTestSec
        if ($s) {
            Write-Host ("== self-test PASSED: the watcher is running (heartbeat {0})" -f $s.last_run) -ForegroundColor Green
        } else {
            Write-Host "== self-test FAILED: no heartbeat - this launch mode does not work here." -ForegroundColor Red
            Show-TaskDiagnostics
            Add-Log "self-test FAILED for mode=$mode"
            if ($mode -eq 'zero-window') {
                Write-Host "   retrying automatically in the fallback mode (-Flash) ..." -ForegroundColor Yellow
                Write-Host "   run:  .\watch.ps1 -Register -Flash" -ForegroundColor Yellow
            }
            exit 1
        }
    } else {
        Write-Host "== self-test SKIPPED: the task could not be started on demand." -ForegroundColor Yellow
        Write-Host "   (it will start at logon and on the keeper tick - check .\watch.ps1 -Status)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host ("== mode: {0}" -f $mode) -ForegroundColor Green
    if ($mode -eq 'zero-window') {
        Write-Host "   the watcher runs as ONE windowless process per logon (no flash at all)" -ForegroundColor Gray
    } elseif ($mode -eq 'flash') {
        Write-Host "   the watcher runs as ONE process per logon: expect ONE brief flash" -ForegroundColor Gray
        Write-Host "   per logon - not per poll (that is 1 per logon instead of 720 per day)." -ForegroundColor Gray
        Write-Host "   IMPORTANT: if a black window appears at logon, LEAVE IT ALONE - it is the" -ForegroundColor Yellow
        Write-Host "   watcher; closing it stops polling until the next keeper tick (10 min)." -ForegroundColor Yellow
        Write-Host "   For ZERO flash, either:" -ForegroundColor Gray
        Write-Host "     * open an ADMIN PowerShell and run:" -ForegroundColor Gray
        Write-Host "         .\watch.ps1 -Unregister ; .\watch.ps1 -Register -Headless" -ForegroundColor Gray
        Write-Host "       (needs .\auth.ps1 -GhLogin done first - gh tokens work in session 0)" -ForegroundColor Gray
        Write-Host "     * or send the host-log tail printed above to the agent to fix the launcher" -ForegroundColor Gray
    } else {
        Write-Host "   session 0 (S4U): no window, but the credential helper must work there" -ForegroundColor Gray
        Write-Host "   (gh auth setup-git is the easy one - see .\auth.ps1)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "== this watcher will now:"
    Write-Host "   poll $Remote/$Branch every $Interval minutes (inside one process)"
    Write-Host "   and run this check when the agent requests one:"
    Write-Host "     $CheckCmd"
    Write-Host "   verify it any time with: .\watch.ps1 -Status   /   .\watch.ps1 -Test"
    Write-Host "   remove any time with:    .\watch.ps1 -Unregister"
    Write-Host "   pause / resume:          .\watch.ps1 -Pause  /  .\watch.ps1 -Resume"
    Write-Host "   this conversation only:  .\watch.ps1 -Focus          (pauses other clones)"
    Write-Host "   restore other clones:    .\watch.ps1 -RestoreParked"
    Write-Host "   after upgrading the skill, re-register so the loop runs the new code"
    Write-Host ("   hands-free: master={0} auto_pull={1} auto_push={2}  (config: hands_free)" -f $HandsFree, $AutoPull, $AutoPush)
    Write-Host "   if a push needs a login window, fix it once with .\auth.ps1 -Setup"
    if (-not $KeepOthers) {
        Write-Host ""
        $parked = @(Invoke-ParkOthers)
        if ($parked.Count -gt 0) {
            Write-Host ("== parked {0} other conversation watcher(s) (kept the task, stopped the loop):" -f $parked.Count) -ForegroundColor Cyan
            foreach ($it in $parked) {
                Write-Host ("     {0}  (was {1})" -f $it.task, $it.state_before)
            }
            Write-Host "   go back later:  cd <that-clone> ; .\watch.ps1 -Focus"
            Write-Host "   or resume all:  .\watch.ps1 -RestoreParked"
        } else {
            Write-Host "== no other git-sync-watch-* tasks were running"
        }
    } else {
        Write-Host "== -KeepOthers: left other conversation watchers running"
    }
    exit 0
}

# ------------------------------------------------------------- single poll
# The poll body is a function on purpose: every exit path returns an exit code
# and the lock is removed by the caller, so a "return" deep inside can never
# leave a stale lock behind (which would stall the watcher until it expires).
# ---------------------------------------------------------------- hands-free
# Convert a gitignore-style glob to a regex. Handles **, *, ? without the
# Escape-then-replace mess (v2.7.0 field port: **/*.pem must match a.pem
# in any folder, and git-pull-arena must not match git-pull-arena-s2).
function Convert-GlobToRegex {
    param([string]$Glob)
    $g = ($Glob -replace '\\', '/')
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $g.Length) {
        $two = ''
        if ($i + 1 -lt $g.Length) { $two = $g.Substring($i, 2) }
        if ($two -eq '**') {
            [void]$sb.Append('.*')
            $i += 2
            if ($i -lt $g.Length -and $g[$i] -eq '/') { $i += 1 }
            continue
        }
        $ch = $g[$i]
        if ($ch -eq '*') { [void]$sb.Append('[^/]*'); $i += 1; continue }
        if ($ch -eq '?') { [void]$sb.Append('[^/]'); $i += 1; continue }
        if (('\^$.|+()[]{}').IndexOf([string]$ch) -ge 0) { [void]$sb.Append('\') }
        [void]$sb.Append($ch)
        $i += 1
    }
    return $sb.ToString()
}

function Test-AutoPushExcluded {
    param([string]$RelPath)
    $p = ($RelPath -replace '\\', '/').TrimStart('/')
    # verdict path owns these - never auto-commit them
    if ($p -match '^results/status/handshake\.json$') { return $true }
    if ($p -match '^results/status/check_r') { return $true }
    foreach ($pat in $AutoPushExclude) {
        $g = ($pat -replace '\\', '/').TrimStart('/')
        if (-not $g) { continue }
        $rx = Convert-GlobToRegex $g
        if ($p -match ('^' + $rx + '$')) { return $true }
        if ($g -notmatch '/') {
            if ($p -match ('(^|/)' + $rx + '$')) { return $true }
        }
    }
    return $false
}

function Get-DirtyPaths {
    $out = @()
    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $raw = git status --porcelain -uall 2>$null
    try { [Console]::OutputEncoding = $prev } catch { }
    if (-not $raw) { return @() }
    foreach ($line in @($raw)) {
        if (-not $line -or $line.Length -lt 4) { continue }
        $rest = $line.Substring(3)
        if ($rest -match ' -> ') { $rest = ($rest -split ' -> ', 2)[1] }
        $rest = $rest.Trim().Trim('"')
        if (-not $rest) { continue }
        if (Test-AutoPushExcluded $rest) { continue }
        $out += $rest
    }
    return $out
}

function Invoke-AutoPull {
    if (-not $AutoPull) { return 0 }
    $sync = Join-Path $repo 'sync.ps1'
    if (-not (Test-Path -LiteralPath $sync)) { $sync = Join-Path $PSScriptRoot 'sync.ps1' }
    if (-not (Test-Path -LiteralPath $sync)) {
        Add-Log 'auto_pull: sync.ps1 missing'
        return 1
    }
    $global:LASTEXITCODE = 0
    $out = (& $sync 2>&1 | Out-String)
    $code = $LASTEXITCODE
    if ($out -and ($out -match 'ERROR|diverg|conflict|FAIL')) { Write-Host $out.TrimEnd() }
    if ($code -ne 0) {
        Add-Log "auto_pull: sync FAILED (exit $code)"
        Set-State @{ last_auto_pull = "fail exit $code" }
        return $code
    }
    $nowAp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Log ('auto_pull: ok at ' + $nowAp)
    Set-State @{ last_auto_pull = 'ok'; last_auto_pull_at = $nowAp }
    return 0
}

function Invoke-AutoPush {
    if (-not $AutoPush) { return 0 }
    $dirty = @(Get-DirtyPaths)
    if ($dirty.Count -eq 0) {
        Add-Log ('auto_push: clean at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        Set-State @{ last_auto_push = 'clean'; last_auto_push_at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
        return 0
    }
    $push = Join-Path $repo 'push.ps1'
    if (-not (Test-Path -LiteralPath $push)) { $push = Join-Path $PSScriptRoot 'push.ps1' }
    if (-not (Test-Path -LiteralPath $push)) {
        Add-Log 'auto_push: push.ps1 missing'
        return 1
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $msg = ("{0} {1} ({2} file(s))" -f $AutoPushPrefix, $stamp, $dirty.Count)
    Write-Host ("== hands-free auto_push: {0} file(s) -> {1}" -f $dirty.Count, $msg) -ForegroundColor Cyan
    Add-Log ("auto_push: {0} file(s): {1}" -f $dirty.Count, (($dirty | Select-Object -First 8) -join ', '))
    $global:LASTEXITCODE = 0
    $out = (& $push -NoPrompt $msg 2>&1 | Out-String)
    $code = $LASTEXITCODE
    if ($out.TrimEnd()) { Write-Host $out.TrimEnd() }
    if ($code -eq 0) {
        Add-Log ("auto_push: ok at " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " ($msg)")
        Set-State @{ last_auto_push = 'ok'; last_auto_push_msg = $msg; last_auto_push_at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); last_auto_push_files = $dirty.Count }
        return 0
    }
    if ($code -eq 4) {
        Add-Log 'auto_push: BLOCKED by auth - run .\\auth.ps1 -Setup'
        Set-State @{ last_auto_push = 'auth blocked'; last_push = 'auth: no silent credential' }
        Write-Host '[AUTH] auto_push could not run silently - run .\\auth.ps1 -Setup -Verify' -ForegroundColor Red
        return 4
    }
    Add-Log "auto_push: FAILED (exit $code)"
    Set-State @{ last_auto_push = "fail exit $code" }
    return $code
}

function Invoke-PollRound {
    $pollStart = Get-Date
    # Every exit of this function MUST leave a closing line in
    # $script:PollSummary; the loop and the manual poll both print it, so a
    # round can never end in silence (that silence is what made the console
    # look frozen on its last line). code/check_loop_summary.* enforces this.
    $script:PollSummary = ''
    try {
        Set-State @{ last_run = $pollStart.ToString('yyyy-MM-dd HH:mm:ss'); last_action = 'poll'; host = $env:COMPUTERNAME; pid = $PID }
        Add-Log "poll start (pid $PID)"

        # low-speed timeouts: a stalled network must not hang the poll forever
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch $Remote --quiet 2>$null

        # read the handshake from the REMOTE tip - do not touch the worktree yet
        # (decode git output as UTF-8 so the Chinese note survives PS 5.1's GBK)
        $hsGit = $Handshake -replace '\\', '/'
        $prevEnc = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
        $raw = git show "$Remote/$Branch`:$hsGit" 2>$null
        try { [Console]::OutputEncoding = $prevEnc } catch { }
        if (-not $raw) {
            $ap = 0; $au = 0
            if ($AutoPull -or $AutoPush) {
                $ap = Invoke-AutoPull
                $au = Invoke-AutoPush
                Add-Log ("hands_free no handshake pull=$ap push=$au")
                Set-State @{ last_action = 'hands_free'; last_note = 'no handshake' }
                $script:PollSummary = ("== hands-free pull={0} push={1} (no handshake yet on {2}/{3})" -f $ap, $au, $Remote, $Branch)
            } else {
                Add-Log 'no handshake yet - idle'
                Set-State @{ last_action = 'idle'; last_note = 'no handshake' }
                $script:PollSummary = ("== idle - no handshake file yet on {0}/{1}" -f $Remote, $Branch)
            }
            return 0
        }
        $hs = (($raw -join "`n") | ConvertFrom-Json)

        # SELF-HEAL: if a verdict commit from an earlier round never made it to
        # the remote (the push step crashed - field report 2026-09-16), the
        # agent would wait forever. Push it on this poll, before anything else.
        $pending = @(((git log --format=%s "$Remote/$Branch..HEAD" 2>$null) | Out-String) -split "`r?`n" |
                     Where-Object { $_ -match '^check: round' })
        if ($pending.Count -gt 0) {
            Write-Host ("== {0} unpushed verdict commit(s) from an earlier round - pushing them now" -f $pending.Count) -ForegroundColor Cyan
            Add-Log ("self-heal: pushing {0} pending verdict commit(s)" -f $pending.Count)
            $pushEx = Join-Path $repo 'push.ps1'
            if (-not (Test-Path -LiteralPath $pushEx)) { $pushEx = Join-Path $PSScriptRoot 'push.ps1' }
            $phOut = (& $pushEx -NoPrompt 'check: publish pending verdict' 2>&1 | Out-String)
            if ($phOut.TrimEnd()) { Write-Host $phOut.TrimEnd() }
            $phCode = $LASTEXITCODE
            Add-Log "self-heal: push exit $phCode"
            if ($phCode -eq 0) { Set-State @{ last_push = 'ok'; last_push_detail = 'self-heal' } }
            else { Set-State @{ last_push = "push failed (exit $phCode)"; last_push_detail = 'self-heal' } }
        }

        if ($hs.arena_state -ne 'awaiting_check' -or $hs.local_state -ne 'pending') {
            $ap = 0; $au = 0
            $note = ("arena={0} local={1}" -f $hs.arena_state, $hs.local_state)
            if ($AutoPull -or $AutoPush) {
                $ap = Invoke-AutoPull
                $au = Invoke-AutoPush
                Add-Log ("hands_free $note pull=$ap push=$au")
                Set-State @{ last_action = 'hands_free'; last_note = $note; last_round = [int]$hs.round }
                $script:PollSummary = ("== hands-free pull={0} push={1} (no check requested, {2})" -f $ap, $au, $note)
            } else {
                Add-Log ("idle ($note)")
                Set-State @{ last_action = 'idle'; last_note = $note; last_round = [int]$hs.round }
                $script:PollSummary = ("== idle - no check requested ({0})" -f $note)
            }
            return 0
        }

        $round = [int]$hs.round
        Write-Host ("== round {0}: the agent requested a local check - syncing ..." -f $round)
        Add-Log "round ${round} requested: $($hs.note)"

        # 1. sync (stash + pull; the same command the user runs by hand)
        $sync = Join-Path $repo 'sync.ps1'
        if (-not (Test-Path -LiteralPath $sync)) { $sync = Join-Path $PSScriptRoot 'sync.ps1' }
        $global:LASTEXITCODE = 0
        & $sync
        if ($LASTEXITCODE -ne 0) {
            Add-Log "round ${round}: sync FAILED (exit $LASTEXITCODE)"
            Set-State @{ last_action = 'error'; last_note = 'sync failed' }
            $script:PollSummary = ("== round {0}: sync FAILED - will retry next poll" -f $round)
            return 1
        }
        # hands-free: flush local dirty files so this round's check sees them
        $null = Invoke-AutoPush

        # 1b. re-read the handshake from the synced worktree (UTF-8, BOM-tolerant)
        $hsAbs = Join-Path $repo $hsGit
        $hs = Get-Content -LiteralPath $hsAbs -Encoding UTF8 -Raw | ConvertFrom-Json

        # 1c. another watcher (another clone) may have answered this round in the
        #     meantime: if the remote tip is no longer "pending", leave it alone
        $prevEnc = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
        $rawRemote = git show "$Remote/$Branch`:$hsGit" 2>$null
        try { [Console]::OutputEncoding = $prevEnc } catch { }
        if ($rawRemote) {
            try {
                $hsRemote = (($rawRemote -join "`n") | ConvertFrom-Json)
                if ($hsRemote.round -eq $round -and $hsRemote.local_state -ne 'pending') {
                    Add-Log "round ${round} already answered remotely ($($hsRemote.local_state)) - skipping"
                    Set-State @{ last_action = 'skipped'; last_note = 'round already answered elsewhere'; last_round = $round }
                    $script:PollSummary = ("== round {0} was already answered elsewhere - nothing to do" -f $round)
                    return 0
                }
            } catch { }
        }

        # 2. run the local check: stdout+stderr captured separately, real exit
        #    code, hard timeout. -NoNewWindow -> the child inherits this
        #    process's (hidden) console, so no window can appear.
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logRel = "results/status/check_r${round}_${stamp}.txt"
        $logAbs = Join-Path $repo ($logRel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logAbs) | Out-Null
        Write-Host ("== running: {0}" -f $CheckCmd)
        Add-Log "round ${round}: running $CheckCmd"

        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $code = 1
        $timedOut = $false
        $stdout = ''
        $stderr = ''
        $t0 = Get-Date
        # The command line from sync.config.json is interpreted by cmd.exe, and
        # its first token is first resolved to an ABSOLUTE path: starting a bare
        # name ("powershell") inside a scheduled task once failed with
        # ERROR_BAD_EXE_FORMAT - "%1 is not a valid Win32 application" (exit
        # 193) - so never hand an unresolved name to Start-Process.
        $resolved = Resolve-ToolPath $CheckCmd
        $cmdLine = $CheckCmd
        if ($resolved.cmdLine) { $cmdLine = $resolved.cmdLine }
        Add-Log "round ${round}: resolved check_cmd -> $cmdLine"
        $cmdExe = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        # the exit code is ALSO written into a file by cmd itself: reading
        # Process.ExitCode back can come out empty (the header "failed (exit )"
        # in the field report), and the marker file cannot lie
        $codeFile = [System.IO.Path]::GetTempFileName()
        # /v:on + !ERRORLEVEL!: with the plain %ERRORLEVEL% form cmd expands the
        # variable while PARSING the line, i.e. before the check has run, so the
        # recorded code was a stale 0 or empty ("failed (exit )" / a false
        # "passed" in the field report)
        $redir = '"' + $cmdLine + ' > "' + $outFile + '" 2> "' + $errFile + '" & echo !ERRORLEVEL! > "' + $codeFile + '""'
        try {
            $p = Start-Process -FilePath $cmdExe -ArgumentList @('/v:on', '/d', '/c', $redir) -WorkingDirectory $repo -NoNewWindow -PassThru
            if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
                $timedOut = $true
                # kill the TREE: the shell alone would leave the real check running
                $null = cmd /c ("taskkill /F /T /PID " + $p.Id + " 2>&1")
                try { $null = $p.WaitForExit(10000) } catch { }
            }
            $ec = $p.ExitCode
            if ($null -eq $ec) { $ec = -1 }
            $code = [int]$ec
        } catch {
            # last resort: run it in-process (no timeout, but a verdict is
            # better than a failed round)
            Add-Log "round ${round}: Start-Process failed ($($_.Exception.Message)) - running in-process"
            $null = cmd /d /c $redir
            $code = $LASTEXITCODE
        }
        if (Test-Path -LiteralPath $codeFile) {
            $rawCode = ((Get-Content -LiteralPath $codeFile -Raw -ErrorAction SilentlyContinue) -replace '[^0-9-]', '')
            if ($rawCode -match '^-?\d+$') { $code = [int]$rawCode }
            Remove-Item -LiteralPath $codeFile -Force -ErrorAction SilentlyContinue
        }
        $secs = [int]((Get-Date) - $t0).TotalSeconds
        # PS 5.1 writes its output in the console code page, so read the
        # captured files with the ANSI encoding - reading them as UTF-8 turned
        # real error messages into mojibake in the field report
        if (Test-Path -LiteralPath $outFile) {
            $t = (Get-Content -LiteralPath $outFile -Raw -Encoding Default -ErrorAction SilentlyContinue)
            if ($t) { $stdout = $t }
        }
        if (Test-Path -LiteralPath $errFile) {
            $t = (Get-Content -LiteralPath $errFile -Raw -Encoding Default -ErrorAction SilentlyContinue)
            if ($t) { $stderr = $t }
        }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue

        if ($timedOut) { $code = 1 }
        $verdict = if ($code -eq 0 -and -not $timedOut) { 'passed' } else { 'failed' }
        # field lesson 2026-09-15 (agentarena-w1): a dead check_cmd chain can
        # exit 0 with ZERO output and every round then "passes" vacuously.
        # Record the elapsed time and make an empty run explicit.
        $body = @()
        if ($stdout) { $body += ($stdout -split "`r?`n") }
        if ($stderr) {
            $body += @('', '--- stderr ---')
            $body += ($stderr -split "`r?`n")
        }
        $outLines = @($body | Where-Object { "$_" -match '\S' })
        if ($outLines.Count -eq 0) { $outLines = @('(check_cmd produced no output; if elapsed is near 0 this pass may be a silent no-op - verify the check really ran)') }
        $head = @("check round $round on $env:COMPUTERNAME - $verdict (exit $code)", "cmd: $CheckCmd", "elapsed: ${secs}s")
        if ($timedOut) { $head += "TIMEOUT: killed after $TimeoutMin min" }
        $text = $head + @('') + $outLines
        [System.IO.File]::WriteAllText($logAbs, ($text -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("== check {0} (log: {1}, {2}s)" -f $verdict, $logRel, $secs) -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })
        Add-Log "round ${round}: check $verdict (exit $code, ${secs}s)"
        Set-State @{ last_action = 'check'; last_round = $round; last_verdict = $verdict; last_check = $logRel; last_check_secs = $secs }

        # 3. update the handshake (worktree) with the verdict - UTF-8 WITHOUT BOM
        #    (PS 5.1 Set-Content -Encoding UTF8 adds a BOM that breaks json.load
        #     on the agent side, so write the bytes explicitly)
        $hs.local_state   = $verdict
        $hs.local_updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $hs.host          = $env:COMPUTERNAME
        $hsJson = $hs | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($hsAbs, $hsJson + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        # 4. push the verdict back (silent mode: a prompt here would hang the poll)
        $push = Join-Path $repo 'push.ps1'
        if (-not (Test-Path -LiteralPath $push)) { $push = Join-Path $PSScriptRoot 'push.ps1' }
        $pushed = $false
        $pushNote = ''
        $pushDetail = ''
        for ($try = 1; $try -le 3; $try++) {
            $global:LASTEXITCODE = 0
            # capture the output so the heartbeat/log can say WHY it failed -
            # "exit 3" alone tells nobody anything (field lesson 2026-09-15)
            $pushOut = (& $push -NoPrompt ("check: round {0} {1}" -f $round, $verdict) 2>&1 | Out-String)
            $pushCode = $LASTEXITCODE
            $pushDetail = (($pushOut -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 4) -join ' / ')
            if ($pushOut) { Write-Host $pushOut }
            if ($pushCode -eq 0) { $pushed = $true; break }
            if ($pushCode -eq 4) {
                $pushNote = 'auth: no silent credential (run auth.ps1 -Setup)'
                Add-Log "round ${round}: push BLOCKED by auth - run .\auth.ps1 -Setup"
                Write-Host '[AUTH] the verdict could not be pushed silently - run .\auth.ps1 -Setup' -ForegroundColor Red
                break
            }
            $pushNote = "push failed (exit $pushCode), attempt $try"
            Add-Log "round ${round}: push attempt $try failed (exit $pushCode): $pushDetail"
            if ($try -lt 3) { Start-Sleep -Seconds 20 }
        }
        if ($pushed) {
            Set-State @{ last_action = 'push'; last_push = 'ok'; last_push_detail = ''; last_round = $round }
            $script:PollSummary = ("== round {0} checked ({1}) - verdict pushed back to {2}/{3}" -f $round, $verdict, $Remote, $Branch)
            return 0
        }
        Set-State @{ last_action = 'push'; last_push = $pushNote; last_push_detail = $pushDetail; last_round = $round }
        $script:PollSummary = ("== round {0} checked ({1}) but the verdict was NOT pushed ({2})" -f $round, $verdict, $pushNote)
        return 1
    } finally {
        # safety net: an unexpected throw must still leave a closing line, so
        # the caller never prints an empty summary
        if (-not $script:PollSummary) {
            $script:PollSummary = "== poll ended without a recorded outcome - see $hostLog"
        }
        Add-Log ("poll took {0}s" -f [int]((Get-Date) - $pollStart).TotalSeconds)
    }
}

# one poll, guarded by a lock (manual runs and the loop can coexist)
function Invoke-PollOnce {
    $skip = $false
    if (Test-Path -LiteralPath $lockFile) {
        # a hard crash can leave the lock behind and stall the watcher forever -
        # a lock older than LockStaleMin (default: check timeout + 15) is stale
        try {
            $lockAge = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalMinutes
            if ($lockAge -gt $LockStaleMin) {
                Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
                Add-Log ("stale lock removed (age: {0} min)" -f [int]$lockAge)
            } else { $skip = $true }
        } catch { $skip = $true }
    }
    if ($skip) {
        $script:PollSummary = '== another poll is still running (lock held) - skipped this tick'
        return 0
    }

    Set-Content -LiteralPath $lockFile -Value (Get-Date).ToString('s')
    $code = 1
    try {
        $code = Invoke-PollRound
    } catch {
        Add-Log "poll crashed: $($_.Exception.Message)"
        Set-State @{ last_action = 'error'; last_note = ("poll crashed: " + $_.Exception.Message) }
        $script:PollSummary = ("== poll CRASHED: {0} - the next tick retries" -f $_.Exception.Message)
        $code = 1
    } finally {
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
    return $code
}

# Print + log the closing line the poll recorded. The loop and the manual poll
# both go through here, so a round can never end in silence and the line is
# never printed twice (the exits themselves only RECORD it).
function Show-PollSummary {
    param([bool]$ToHost = $true)
    $sum = [string]$script:PollSummary
    if (-not $sum.Trim()) { $sum = '== poll ended without a recorded outcome' }
    # Timestamp every closing line: "did it actually run, and when?" must be
    # answerable from the window/log alone (user request 2026-09-16).
    $sum = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $sum)
    if ($ToHost) { Write-Host $sum }
    Add-Log $sum
}

if ($Loop) {
    # Task Scheduler can hand the process it starts the console of whoever
    # registered the task, and a loop that lives forever then occupies that
    # window ("the console looks stuck" - field report 2026-09-16). Re-launch
    # ourselves hidden with a console of our own and leave the visible one alone.
    if ($env:GIT_SYNC_WATCH_DETACHED -ne '1' -and (Test-VisibleConsole)) {
        try {
            $psExe = Get-PowerShellExe
            $env:GIT_SYNC_WATCH_DETACHED = '1'
            $null = Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', $PSCommandPath, '-Loop', '-Interval', $Interval, '-KeeperMin', $KeeperMin)
            Add-Log 'loop: re-launched itself detached (hidden) - this console is free again'
            Start-Sleep -Seconds 2
            exit 0
        } catch {
            Add-Log "loop: could not detach ($($_.Exception.Message)) - staying in this console"
        }
    }
    # single instance: the keeper trigger starts the task again every KeeperMin
    # minutes and now that the task instance exits after detaching, without this
    # guard every keeper tick would add another loop
    $existing = Get-LoopPid
    if ($existing -gt 0 -and $existing -ne $PID -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
        Add-Log "loop: another loop is already running (pid $existing) - exiting this instance"
        exit 0
    }
    # no pid file => the running loop is from an OLDER version (it never wrote
    # one): stop those before starting ours, otherwise two loops poll in parallel
    $stale = Get-WatchLoops
    if ($stale.Count -gt 0) {
        Add-Log ("loop: found {0} loop(s) from an older version - stopping them: {1}" -f $stale.Count, (($stale | ForEach-Object { $_.Pid }) -join ', '))
        $null = Stop-StaleLoops
    }
    [System.IO.File]::WriteAllText($loopFile, "$PID", (New-Object System.Text.UTF8Encoding($false)))
    Add-Log "loop start (pid $PID, every ${Interval}m, skill v$skillVer, detach=$($env:GIT_SYNC_WATCH_DETACHED))"
    # If this process ended up owning a visible console, say what is going on
    # ONCE and then keep saying when the next poll is: the loop never returns to
    # a prompt, so without this the window looks frozen on its last line
    # (field question 2026-09-16: "why does it stay stuck on 'verdict pushed'?").
    $attached = Test-VisibleConsole
    if ($attached) {
        Write-Host ""
        Write-Host "== THIS WINDOW IS THE WATCHER (pid $PID)." -ForegroundColor Cyan
        Write-Host "   It stays open on purpose: it polls every $Interval min and pushes the verdict" -ForegroundColor Gray
        Write-Host "   by itself. No prompt will come back here." -ForegroundColor Gray
        Write-Host "   * leave it open, or close it (the keeper tick restarts it within ${KeeperMin} min)" -ForegroundColor Gray
        Write-Host "   * type commands in a NEW PowerShell window" -ForegroundColor Gray
        Write-Host "   * Ctrl+C here stops this loop:  .\watch.ps1 -Pause  /  -Resume" -ForegroundColor Gray
        Write-Host ""
    }
    try {
        while ($true) {
            $script:PollSummary = ''
            $null = Invoke-PollOnce
            # 1) what this tick concluded, 2) when the next one is - always
            #    both, to the console (when there is one) and to the host log
            Show-PollSummary $attached
            $next = (Get-Date).AddSeconds($Interval * 60)
            $line = "== next poll at {0} (Ctrl+C stops this loop)" -f $next.ToString('HH:mm:ss')
            if ($attached) { Write-Host $line -ForegroundColor DarkGray }
            Add-Log $line
            Start-Sleep -Seconds ($Interval * 60)
        }
    } finally {
        Remove-Item -LiteralPath $loopFile -Force -ErrorAction SilentlyContinue
        Add-Log "loop exit (pid $PID)"
    }
} else {
    # manual single poll (.\watch.ps1 with no -Loop): the same closing line the
    # loop prints, then an explicit end marker - a bare return to the prompt
    # looked like a crash / a hang
    $script:PollSummary = ''
    $code = Invoke-PollOnce
    Show-PollSummary $true
    $line = "== finished at {0} (manual poll; the scheduled loop keeps running)" -f (Get-Date).ToString('HH:mm:ss')
    Write-Host $line
    Add-Log $line
    exit $code
}
