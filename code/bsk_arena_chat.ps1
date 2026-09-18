# bsk_arena_chat.ps1 - drive the LOCAL browser through the bsk CLI and prove a
# chat round on a web page really happened.
#
# This file runs ON THE USER'S WINDOWS MACHINE, started by the git-sync watcher
# through code\local_check.ps1. The Arena sandbox can never run it: the bsk
# daemon and the browser extension only exist on the real machine.
#
# It reads its task from results/status/browser_task.json so that the agent can
# change the URL / message from the sandbox without editing any .ps1
# (.ps1 files must stay ASCII-only - Windows PowerShell 5.1 decodes them as
#  ANSI/GBK - so all non-ASCII text lives in that JSON).
#
# Task file keys (all optional except url):
#   url                 page to open in the Agent Window
#   message             text to send in the page's composer
#   composer_hint       regex matched against the observe line of the composer
#   send_key            key used to submit (default Enter)
#   reply_timeout_sec   how long to wait for the page to answer (default 180)
#   settle_sec          reply must stay unchanged this long (default 8)
#   require_reply       $true/$false - fail the round when no reply appears
#   out_dir             evidence directory (default deliverable/browser-loop)
#   borrow_tab_match    optional: borrow an already open user tab whose URL or
#                       title matches this regex instead of navigating
#   login_pattern       regex that marks a sign-in wall (localised wording)
#   ready_timeout_sec   how long to wait for the app to render an input field
#                       (single-page apps answer 'load' before painting)
#
# Evidence written to <out_dir>:
#   result.json          machine-readable verdict (what success_criteria reads)
#   observe_before.txt   page observation before sending
#   observe_after.txt    page observation after the reply settled
#   transcript.md        human-readable round summary
#   page.png             screenshot of the page after the round
#
# Exit 0 = the round succeeded, 1 = it failed (the watcher pushes the log back).

[CmdletBinding()]
param(
    [string]$TaskFile = 'results/status/browser_task.json',
    [string]$OutDir = '',
    [switch]$SkipSend
)

$ErrorActionPreference = 'Continue'
Set-Location (Join-Path $PSScriptRoot '..')   # repo root (this file lives in code\)

$script:Fail = 0
$script:Notes = New-Object System.Collections.ArrayList

function Say {
    param([string]$Text)
    Write-Output $Text          # Write-Output on purpose: the watcher captures stdout
    [void]$script:Notes.Add($Text)
}

function Fail-Round {
    param([string]$Text)
    Say ('[FAIL] ' + $Text)
    $script:Fail = 1
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 0. the task
$task = $null
if (Test-Path -LiteralPath $TaskFile) {
    try {
        $task = Get-Content -LiteralPath $TaskFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail-Round ('browser task file is not valid JSON: ' + $_.Exception.Message)
    }
} else {
    Say ('== browser round: no task file at ' + $TaskFile + ' - nothing to do (skipped)')
    exit 0
}
if ($null -eq $task) { exit 1 }

if ($task.enabled -eq $false) {
    Say '== browser round: task.enabled is false - skipped'
    exit 0
}

$url = [string]$task.url
if (-not $url) {
    Fail-Round 'browser task has no "url"'
    exit 1
}
$message        = [string]$task.message
$composerHint   = [string]$task.composer_hint
$sendKey        = if ($task.send_key) { [string]$task.send_key } else { 'Enter' }
$replyTimeout   = if ($task.reply_timeout_sec) { [int]$task.reply_timeout_sec } else { 180 }
$settleSec      = if ($task.settle_sec) { [int]$task.settle_sec } else { 8 }
$requireReply   = $true
if ($null -ne $task.require_reply) { $requireReply = [bool]$task.require_reply }
$borrowMatch    = [string]$task.borrow_tab_match
$loginPattern   = if ($task.login_pattern) { [string]$task.login_pattern } else { '(?i)\b(sign in|log in)\b' }
$readyTimeout   = if ($task.ready_timeout_sec) { [int]$task.ready_timeout_sec } else { 90 }
if (-not $OutDir) {
    $OutDir = if ($task.out_dir) { [string]$task.out_dir } else { 'deliverable/browser-loop' }
}
$OutDir = $OutDir -replace '/', '\'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Say '== browser round (BrowserSkill)'
Say ('   task      : ' + $TaskFile)
Say ('   url       : ' + $url)
Say ('   send      : ' + $(if ($SkipSend -or -not $message) { '(read-only)' } else { ($message.Length.ToString() + ' chars') }))
Say ('   evidence  : ' + $OutDir)

# ---------------------------------------------------------------- 1. the CLI
# Never let a browser command auto-start a daemon from inside the scheduled
# task: the watcher's process can be torn down between polls and would leave a
# half-started daemon behind. The user's own daemon is the one we talk to.
$env:BSK_AUTO_START = '0'

$bsk = ''
$cmd = Get-Command bsk -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd -and $cmd.Source) { $bsk = [string]$cmd.Source }
if (-not $bsk) {
    foreach ($cand in @(
        (Join-Path $HOME '.local\bin\bsk.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\bsk\bsk.exe'))) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $bsk = $cand; break }
    }
}
if (-not $bsk) {
    Fail-Round 'bsk CLI not found on PATH (install it, or open a new shell so PATH is refreshed)'
    exit 1
}
Say ('   bsk       : ' + $bsk)

function Invoke-Bsk {
    # Runs bsk and returns @{ code; out; err }.
    #
    # Round 2 on LAPTOP-R77M5D6M returned "exit -1" with EMPTY stdout AND
    # stderr from Start-Process -PassThru (ExitCode came back null, nothing was
    # written to the redirect files). A verdict with no message is useless, so
    # drive System.Diagnostics.Process directly: it gives the real exit code
    # and both streams, and it never needs a temp file.
    param([string[]]$BskArgs, [int]$TimeoutSec = 180)

    $res = @{ code = 1; out = ''; err = ''; how = 'process' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bsk
    # PS 5.1 runs on .NET Framework, where ProcessStartInfo has NO ArgumentList
    # (that is .NET Core 2.1+). Use it when present, otherwise build the single
    # Arguments string with Windows' own quoting rules.
    $useList = $false
    try { if ($null -ne $psi.ArgumentList) { $useList = $true } } catch { $useList = $false }
    if ($useList) {
        foreach ($a in $BskArgs) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $parts = @()
        foreach ($a in $BskArgs) {
            $v = [string]$a
            # escape backslashes that precede the closing quote, then the quotes
            $v = $v -replace '(\\+)$', '$1$1'
            $v = $v -replace '"', '\"'
            $parts += ('"' + $v + '"')
        }
        $psi.Arguments = ($parts -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path
    # The page and the CLI both speak UTF-8; PS 5.1 would otherwise decode the
    # JSON in the console code page and mangle every non-ASCII reply.
    try {
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding  = New-Object System.Text.UTF8Encoding($false)
    } catch { }
    $psi.EnvironmentVariables['BSK_AUTO_START'] = '0'

    $proc = $null
    try {
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # Read both streams asynchronously: reading one to the end first can
        # deadlock when the other fills its pipe buffer.
        $tOut = $proc.StandardOutput.ReadToEndAsync()
        $tErr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $null = cmd /c ('taskkill /F /T /PID ' + $proc.Id + ' 2>&1') } catch { }
            try { $null = $proc.WaitForExit(10000) } catch { }
            $res.code = 124
            $res.err = 'timed out after ' + $TimeoutSec + 's'
        } else {
            $res.code = [int]$proc.ExitCode
        }
        try { $res.out = [string]$tOut.Result } catch { }
        try { $res.err = ([string]$res.err + [string]$tErr.Result).Trim() } catch { }
    } catch {
        $res.code = -1
        $res.err = 'could not start ' + $bsk + ': ' + $_.Exception.Message
        $res.how = 'start-failed'
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }

    # A -1 / empty-everything result means the .NET path told us nothing.
    # cmd.exe redirection is the mechanism watch.ps1 already relies on in the
    # field, so use it as the fallback rather than reporting a blank failure.
    if ($res.code -eq -1 -and -not $res.out -and -not $res.err) {
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $codeFile = [System.IO.Path]::GetTempFileName()
        $quoted = @('"' + $bsk + '"')
        foreach ($a in $BskArgs) { $quoted += ('"' + ([string]$a).Replace('"', '\"') + '"') }
        $line = '"' + ($quoted -join ' ') + ' > "' + $outFile + '" 2> "' + $errFile + '" & echo !ERRORLEVEL! > "' + $codeFile + '""'
        $cmdExe = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        try {
            $p2 = Start-Process -FilePath $cmdExe -ArgumentList @('/v:on', '/d', '/c', $line) `
                    -WorkingDirectory (Get-Location).Path -NoNewWindow -PassThru
            if (-not $p2.WaitForExit($TimeoutSec * 1000)) {
                try { $null = cmd /c ('taskkill /F /T /PID ' + $p2.Id + ' 2>&1') } catch { }
            }
        } catch { }
        $rawCode = (Get-Content -LiteralPath $codeFile -Raw -ErrorAction SilentlyContinue)
        if ($rawCode) {
            $rawCode = ($rawCode -replace '[^0-9-]', '')
            if ($rawCode -match '^-?\d+$') { $res.code = [int]$rawCode }
        }
        $t = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($t) { $res.out = $t }
        $t = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($t) { $res.err = $t }
        $res.how = 'cmd-fallback'
        foreach ($f in @($outFile, $errFile, $codeFile)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    return $res
}

function Get-BskJson {
    param([string[]]$BskArgs, [int]$TimeoutSec = 180)
    $r = Invoke-Bsk -BskArgs $BskArgs -TimeoutSec $TimeoutSec
    $obj = $null
    if ($r.out) {
        $raw = $r.out.Trim()
        $start = $raw.IndexOf('{')
        if ($start -lt 0) { $start = $raw.IndexOf('[') }
        if ($start -ge 0) {
            try { $obj = ($raw.Substring($start) | ConvertFrom-Json) } catch { $obj = $null }
        }
    }
    return @{ code = $r.code; out = $r.out; err = $r.err; json = $obj }
}

# ---------------------------------------------------------------- 2. daemon + browser
$st = Get-BskJson -BskArgs @('status', '--json') -TimeoutSec 60
if ($st.code -ne 0 -or $null -eq $st.json) {
    Fail-Round ('bsk status failed (exit ' + $st.code + ', via ' + $st.how + '). Start the daemon and connect the extension, then retry.')
    if ($st.out) { Say ('       stdout: ' + ($st.out.Trim())) }
    if ($st.err) { Say ('       stderr: ' + ($st.err.Trim())) }
    if (-not $st.out -and -not $st.err) {
        Say '       (the CLI produced no output at all - run this by hand in the same account:'
        Say ('        "' + $bsk + '" status --json)')
    }
    exit 1
}
$browsers = @($st.json.browsers)
Say ('== daemon ok: v' + $st.json.daemon_version + ' protocol ' + $st.json.protocol_version + ', ws_port ' + $st.json.ws_port + ', browsers ' + $browsers.Count)
if ($browsers.Count -lt 1) {
    Fail-Round 'no browser extension is connected - open the BrowserSkill extension and connect it, then retry'
    exit 1
}
$browserLabel = ''
try { $browserLabel = [string]$browsers[0].label } catch { }
$browserId = ''
try { $browserId = [string]$browsers[0].instance_id } catch { }
Say ('   browser   : ' + $browserLabel + ' (' + $browserId + ')')

# ---------------------------------------------------------------- 3. session
$startArgs = @('session', 'start', '--json', '--name', 'git-sync browser round')
if ($browsers.Count -gt 1 -and $browserId) { $startArgs += @('--browser', $browserId) }
$ss = Get-BskJson -BskArgs $startArgs -TimeoutSec 120
if ($ss.code -ne 0 -or $null -eq $ss.json -or -not $ss.json.session_id) {
    Fail-Round ('bsk session start failed (exit ' + $ss.code + ')')
    if ($ss.out) { Say ('       stdout: ' + $ss.out.Trim()) }
    if ($ss.err) { Say ('       stderr: ' + $ss.err.Trim()) }
    exit 1
}
$sid = [string]$ss.json.session_id
Say ('== session   : ' + $sid)

$result = [ordered]@{
    ok               = $false
    generated_by     = 'code/bsk_arena_chat.ps1'
    host             = $env:COMPUTERNAME
    started_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    daemon_version   = [string]$st.json.daemon_version
    protocol_version = [string]$st.json.protocol_version
    browser          = $browserLabel
    session_id       = $sid
    url              = $url
    borrowed_tab_id  = $null
    message_sent     = $false
    message          = $message
    composer_ref     = ''
    reply_detected   = $false
    reply_excerpt    = ''
    reply_wait_sec   = 0
    screenshot       = ''
    steps            = @()
    errors           = @()
}
$borrowedTab = $null

function Add-Step {
    param([string]$Name, [string]$State, [string]$Detail = '')
    $result.steps += ,([ordered]@{ step = $Name; state = $State; detail = $Detail })
    Say ('   - ' + $Name + ': ' + $State + $(if ($Detail) { ' (' + $Detail + ')' } else { '' }))
}

function Get-Observation {
    param([int]$TimeoutSec = 120)
    $o = Invoke-Bsk -BskArgs @('observe', '--session', $sid) -TimeoutSec $TimeoutSec
    if ($o.code -ne 0) { return '' }
    return [string]$o.out
}

try {
    # ------------------------------------------------------------ 4. the page
    if ($borrowMatch) {
        $tl = Get-BskJson -BskArgs @('tab', 'list', '--scope', 'user', '--session', $sid, '--json') -TimeoutSec 60
        $hit = $null
        if ($tl.code -eq 0 -and $tl.json) {
            $tabs = @()
            if ($tl.json.tabs) { $tabs = @($tl.json.tabs) } else { $tabs = @($tl.json) }
            foreach ($t in $tabs) {
                $u = [string]$t.url
                $ti = [string]$t.title
                if (($u -and $u -match $borrowMatch) -or ($ti -and $ti -match $borrowMatch)) { $hit = $t; break }
            }
        }
        if ($hit) {
            $tid = [string]$hit.id
            if (-not $tid) { $tid = [string]$hit.tab_id }
            $b = Invoke-Bsk -BskArgs @('tab', 'borrow', $tid, '--session', $sid) -TimeoutSec 180
            if ($b.code -eq 0) {
                $borrowedTab = $tid
                $result.borrowed_tab_id = $tid
                Add-Step 'borrow user tab' 'ok' ('tab ' + $tid)
            } else {
                Add-Step 'borrow user tab' 'declined' ('exit ' + $b.code + ' - falling back to a new tab')
            }
        } else {
            Add-Step 'borrow user tab' 'no match' 'falling back to a new tab'
        }
    }

    if (-not $borrowedTab) {
        $nav = Invoke-Bsk -BskArgs @('navigate', $url, '--session', $sid, '--wait-until', 'load', '--timeout', '60s') -TimeoutSec 120
        if ($nav.code -ne 0) {
            Add-Step 'navigate' 'FAILED' ('exit ' + $nav.code + ' ' + ($nav.err + $nav.out).Trim())
            throw ('navigate failed: ' + $url)
        }
        Add-Step 'navigate' 'ok' $url
    }

    # A single-page app answers `load` long before it has painted anything:
    # round 3 observed only the page shell plus a Grammarly overlay (325 chars)
    # and concluded there was no composer. So poll the observation until a real
    # input field shows up (or ready_timeout_sec runs out) instead of guessing
    # a sleep duration.
    $before = ''
    $readyT0 = Get-Date
    $sawField = $false
    while ($true) {
        $before = Get-Observation
        if ($before) {
            $sawField = ($before -match '(?i)\b(textbox|searchbox|combobox|textarea)\b')
            if ($sawField -or -not $message -or $SkipSend) { break }
        }
        if (((Get-Date) - $readyT0).TotalSeconds -ge $readyTimeout) { break }
        Start-Sleep -Seconds 3
    }
    $readySec = [int]((Get-Date) - $readyT0).TotalSeconds
    if (-not $before) {
        Add-Step 'observe (before)' 'FAILED' 'empty observation'
        throw 'observe returned nothing - the page may not be controllable'
    }
    Write-Utf8NoBom (Join-Path $OutDir 'observe_before.txt') $before
    Add-Step 'observe (before)' 'ok' ($before.Length.ToString() + ' chars after ' + $readySec + 's, input field: ' + $sawField)

    # When the app never rendered a field, save everything that helps diagnose
    # it from the sandbox: the accessibility snapshot and a screenshot.
    if ($message -and -not $SkipSend -and -not $sawField) {
        $snap = Invoke-Bsk -BskArgs @('snapshot', '--session', $sid) -TimeoutSec 120
        if ($snap.out) { Write-Utf8NoBom (Join-Path $OutDir 'snapshot_stuck.txt') $snap.out }
        $stuckShot = Join-Path $OutDir 'page.png'
        $null = Invoke-Bsk -BskArgs @('screenshot', '--session', $sid, '--out', $stuckShot) -TimeoutSec 180
        Add-Step 'page never rendered an input' 'DIAG' ('saved snapshot_stuck.txt + page.png after ' + $readySec + 's')
    }

    # A login wall is the one thing this loop cannot fix by itself. The pattern
    # is read from the task JSON (login_pattern) because this file must stay
    # ASCII-only and the wording is often localised.
    if ($loginPattern -and ($before -match $loginPattern) -and ($before -notmatch '(?i)textbox')) {
        Add-Step 'login check' 'WARN' 'the page looks like a sign-in wall - log in once in that browser profile'
    }

    # -------------------------------------------------------- 5. the composer
    if ($message -and -not $SkipSend) {
        $lines = $before -split "`r?`n"
        $cands = @()
        foreach ($ln in $lines) {
            if ($ln -match '@e(\d+)') {
                $ref = '@e' + $Matches[1]
                $isField = ($ln -match '(?i)\b(textbox|searchbox|combobox|textarea)\b')
                if (-not $isField) { continue }
                if ($composerHint -and ($ln -notmatch $composerHint)) { continue }
                $cands += ,@{ ref = $ref; line = $ln.Trim() }
            }
        }
        if ($cands.Count -lt 1) {
            $why = if ($composerHint) { 'no textbox matched composer_hint ' + $composerHint } else { 'no textbox in the observation' }
            Add-Step 'find composer' 'FAILED' ($why + '; observation is in observe_before.txt (' + $before.Length + ' chars)')
            throw 'no composer found on the page'
        }
        # the composer of a chat page is the LAST input in document order
        $chosen = $cands[$cands.Count - 1]
        $result.composer_ref = [string]$chosen.ref
        Add-Step 'find composer' 'ok' ($chosen.ref + ' ' + $chosen.line)

        $fl = Invoke-Bsk -BskArgs @('fill', $chosen.ref, '--value', $message, '--session', $sid) -TimeoutSec 120
        if ($fl.code -ne 0) {
            Add-Step 'fill composer' 'FAILED' ('exit ' + $fl.code + ' ' + ($fl.err + $fl.out).Trim())
            throw 'fill failed'
        }
        Add-Step 'fill composer' 'ok' ($message.Length.ToString() + ' chars')

        $pr = Invoke-Bsk -BskArgs @('press', $sendKey, '--ref', $chosen.ref, '--session', $sid) -TimeoutSec 120
        if ($pr.code -ne 0) {
            Add-Step ('press ' + $sendKey) 'FAILED' ('exit ' + $pr.code + ' ' + ($pr.err + $pr.out).Trim())
            throw 'send key failed'
        }
        $result.message_sent = $true
        Add-Step ('press ' + $sendKey) 'ok' 'message submitted'

        # ----------------------------------------------------- 6. the reply
        # A reply is "new page text that is not the echo of what we typed".
        # Poll until the page stops growing for settle_sec, or we run out of
        # time. Never spam the page: observe only, no extra clicks.
        $t0 = Get-Date
        $prevText = ''
        $stableSince = $null
        $after = $before
        while (((Get-Date) - $t0).TotalSeconds -lt $replyTimeout) {
            Start-Sleep -Seconds 5
            $now = Get-Observation
            if (-not $now) { continue }
            $after = $now
            $grew = ($now.Length -gt $before.Length + 20)
            if ($grew -and $now -eq $prevText) {
                if ($null -eq $stableSince) { $stableSince = Get-Date }
                if (((Get-Date) - $stableSince).TotalSeconds -ge $settleSec) { break }
            } else {
                $stableSince = $null
            }
            $prevText = $now
        }
        $result.reply_wait_sec = [int]((Get-Date) - $t0).TotalSeconds

        # new lines that appeared after sending, minus the echo of our message
        $beforeSet = @{}
        foreach ($ln in ($before -split "`r?`n")) { $beforeSet[($ln -replace '@e\d+', '@e').Trim()] = $true }
        $newLines = @()
        foreach ($ln in ($after -split "`r?`n")) {
            $key = ($ln -replace '@e\d+', '@e').Trim()
            if (-not $key) { continue }
            if ($beforeSet.ContainsKey($key)) { continue }
            if ($message -and $key.Contains($message.Trim())) { continue }
            $newLines += $key
        }
        $replyText = ($newLines -join "`n").Trim()
        if ($replyText.Length -gt 0) {
            $result.reply_detected = $true
            $excerpt = $replyText
            if ($excerpt.Length -gt 600) { $excerpt = $excerpt.Substring(0, 600) + ' ...' }
            $result.reply_excerpt = $excerpt
            Add-Step 'wait for reply' 'ok' ($newLines.Count.ToString() + ' new lines in ' + $result.reply_wait_sec + 's')
        } else {
            Add-Step 'wait for reply' 'NO REPLY' ('nothing new after ' + $result.reply_wait_sec + 's')
        }
        Write-Utf8NoBom (Join-Path $OutDir 'observe_after.txt') $after
    } else {
        Write-Utf8NoBom (Join-Path $OutDir 'observe_after.txt') $before
        Add-Step 'send message' 'skipped' 'read-only round'
    }

    # ------------------------------------------------------ 7. visual proof
    $shot = Join-Path $OutDir 'page.png'
    $sc = Invoke-Bsk -BskArgs @('screenshot', '--session', $sid, '--out', $shot) -TimeoutSec 180
    if ($sc.code -eq 0 -and (Test-Path -LiteralPath $shot)) {
        $result.screenshot = ($OutDir -replace '\\', '/') + '/page.png'
        Add-Step 'screenshot' 'ok' ((Get-Item -LiteralPath $shot).Length.ToString() + ' B')
    } else {
        Add-Step 'screenshot' 'FAILED' ('exit ' + $sc.code + ' ' + ($sc.err + $sc.out).Trim())
    }

    # the round is a success when the page answered (or when no reply was required)
    if ($message -and -not $SkipSend) {
        if ($result.message_sent -and ($result.reply_detected -or -not $requireReply)) { $result.ok = $true }
    } elseif ($before) {
        $result.ok = $true
    }
} catch {
    $result.errors += [string]$_.Exception.Message
    Say ('[FAIL] browser round: ' + $_.Exception.Message)
} finally {
    if ($borrowedTab) {
        $rb = Invoke-Bsk -BskArgs @('tab', 'return', $borrowedTab, '--session', $sid) -TimeoutSec 120
        Add-Step 'return borrowed tab' $(if ($rb.code -eq 0) { 'ok' } else { 'FAILED' }) ('tab ' + $borrowedTab)
    }
    # Always stop the session: it also returns tabs and closes the Agent Window.
    $sp = Invoke-Bsk -BskArgs @('session', 'stop', $sid) -TimeoutSec 180
    Add-Step 'session stop' $(if ($sp.code -eq 0) { 'ok' } else { 'FAILED' }) $sid
}

$result.finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# ---------------------------------------------------------------- 8. evidence
$json = ($result | ConvertTo-Json -Depth 8)
Write-Utf8NoBom (Join-Path $OutDir 'result.json') ($json + "`r`n")

$md = New-Object System.Collections.ArrayList
[void]$md.Add('# BrowserSkill round - ' + $result.finished_utc)
[void]$md.Add('')
[void]$md.Add('| field | value |')
[void]$md.Add('| --- | --- |')
[void]$md.Add('| host | ' + $result.host + ' |')
[void]$md.Add('| browser | ' + $result.browser + ' |')
[void]$md.Add('| daemon | v' + $result.daemon_version + ' (protocol ' + $result.protocol_version + ') |')
[void]$md.Add('| session | ' + $result.session_id + ' |')
[void]$md.Add('| url | ' + $result.url + ' |')
[void]$md.Add('| message sent | ' + $result.message_sent + ' |')
[void]$md.Add('| reply detected | ' + $result.reply_detected + ' (' + $result.reply_wait_sec + 's) |')
[void]$md.Add('| ok | ' + $result.ok + ' |')
[void]$md.Add('')
[void]$md.Add('## Steps')
[void]$md.Add('')
foreach ($s in $result.steps) {
    [void]$md.Add('- ' + $s.step + ': ' + $s.state + $(if ($s.detail) { ' - ' + $s.detail } else { '' }))
}
if ($result.message) {
    [void]$md.Add('')
    [void]$md.Add('## Message sent')
    [void]$md.Add('')
    [void]$md.Add('```text')
    [void]$md.Add($result.message)
    [void]$md.Add('```')
}
if ($result.reply_excerpt) {
    [void]$md.Add('')
    [void]$md.Add('## Reply (new page text)')
    [void]$md.Add('')
    [void]$md.Add('```text')
    [void]$md.Add($result.reply_excerpt)
    [void]$md.Add('```')
}
if ($result.errors.Count -gt 0) {
    [void]$md.Add('')
    [void]$md.Add('## Errors')
    [void]$md.Add('')
    foreach ($e in $result.errors) { [void]$md.Add('- ' + $e) }
}
Write-Utf8NoBom (Join-Path $OutDir 'transcript.md') (($md -join "`r`n") + "`r`n")

if ($result.ok) {
    Say ('== browser round PASSED (evidence in ' + $OutDir + ')')
    exit 0
}
Fail-Round ('browser round did not reach its goal - see ' + $OutDir + '\transcript.md')
exit 1
