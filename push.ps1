# push.ps1 (skill version) - commit local changes and push them to the remote.
#
# Usage (inside the repo folder):
#     .\push.ps1                      # auto commit message
#     .\push.ps1 "add midterm files"  # custom commit message
#     .\push.ps1 -Branch other/branch
#     .\push.ps1 -Gate "msg"          # also run the repo gate before committing
#                                      # (needs bash - it ships with Git for Windows)
#     .\push.ps1 -Prompt "msg"        # allow git to ask for credentials (window!)
#     .\push.ps1 -NoPrompt "msg"      # force silent mode (the default anyway)
#
# Branch / remote come from sync.config.json when present. A safety guard
# refuses to push to main / master, so a stray edit can never move the shared
# branch.
#
# NO PROMPTS BY DEFAULT: every git call runs with GIT_TERMINAL_PROMPT=0,
# GCM_INTERACTIVE=never and -c credential.interactive=false, so a push can
# never block on a login window. If that leaves git without a credential it
# fails fast with exit code 4 and tells you to run .\auth.ps1 -Setup once
# (that is the same silent mode the watcher uses - see auth.ps1).
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [string]$Message = '',
    [string]$Branch  = '',
    [string]$Remote  = '',
    [string]$Config = '',
    [switch]$Gate,
    [switch]$NoPrompt,
    [switch]$Prompt
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
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if (-not $Branch -and $cfg.branch) { $Branch = [string]$cfg.branch }
    if (-not $Remote -and $cfg.remote) { $Remote = [string]$cfg.remote }
}
if (-not $Remote) { $Remote = 'origin' }
if (-not $Branch) { $Branch = (git rev-parse --abbrev-ref HEAD).Trim() }

# -------------------------------------------------------------------- guard
if ($Branch -eq 'main' -or $Branch -eq 'master') {
    Write-Host "[REFUSED] pushing straight to $Branch is not allowed." -ForegroundColor Red
    Write-Host "          Set a working branch in skills\git-sync\sync.config.json" -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------------------ prompt policy
# default: silent. -Prompt restores the interactive behaviour (a credential
# window may appear); the watcher always calls this script in silent mode.
$noPrompt = $true
if ($NoPrompt.IsPresent) { $noPrompt = $true }
elseif ($Prompt.IsPresent) { $noPrompt = $false }
elseif ($env:GIT_SYNC_PROMPT -eq '1') { $noPrompt = $false }
$script:GP = @()
if ($noPrompt) {
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    $env:GH_PROMPT_DISABLED = '1'
    $env:GIT_ASKPASS = ''
    $env:SSH_ASKPASS = ''
    $script:GP = @('-c', 'credential.interactive=false', '-c', 'core.askpass=')
} else {
    # -Prompt: make interactivity EXPLICIT. A machine-level
    # credential.interactive=false (some helpers write it) would otherwise
    # silently keep the login window away and the push would just fail.
    Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
    Remove-Item Env:GH_PROMPT_DISABLED -ErrorAction SilentlyContinue
    $script:GP = @('-c', 'credential.interactive=true')
    Write-Host "== note: this run may open a login window once - it stores the credential" -ForegroundColor Yellow
}

# explicit argument arrays on purpose: no parameter-name guessing in the calls
# Every git call goes through cmd.exe. Reason (field report 2026-09-16): git
# writes perfectly ordinary lines to STDERR ("Already on 'branch'", "Switched to
# branch ..."), and Windows PowerShell 5.1 turns a native command's stderr into
# a TERMINATING error while $ErrorActionPreference is 'Stop'. That aborted the
# watcher's poll in the middle of the push step, so the verdict never reached
# the branch. Through cmd.exe the stderr stays stderr and the exit code is
# git's own.
function GitLine([string[]]$a) {
    $line = 'git'
    foreach ($x in ($script:GP + $a)) {
        if ($x -match '[\s"]') { $line += ' "' + ($x -replace '"', '""') + '"' } else { $line += ' ' + $x }
    }
    return $line
}
function GitRun([string[]]$a) {
    $null = (cmd /c ((GitLine $a) + ' 2>&1') | Out-String)
    return $LASTEXITCODE
}
function GitShow([string[]]$a) {
    # run it and let the caller see the output on screen
    $out = (cmd /c ((GitLine $a) + ' 2>&1') | Out-String)
    $code = $LASTEXITCODE
    if ($out.TrimEnd()) { Write-Host $out.TrimEnd() }
    return $code
}
function GitOut([string[]]$a) {
    $out = (cmd /c ((GitLine $a) + ' 2>&1') | Out-String)
    return @{ code = $LASTEXITCODE; text = $out.TrimEnd() }
}
function Test-AuthFailure([string]$text) {
    # the exact wording differs per helper; keep every variant that has been
    # seen in the field ("Cannot prompt because user interactivity has been
    # disabled." is GCM 2.x with GCM_INTERACTIVE=never)
    $patterns = @(
        'Could not read from remote repository',
        'could not read Username',
        'unable to get password from user',
        'could not read Password',
        'terminal prompts disabled',
        'Cannot prompt because user interactivity',
        'interactivity has been disabled',
        'Authentication failed',
        'Invalid username or (password|token)',
        'Support for password authentication was removed',
        'Permission denied \(publickey\)',
        '403 Forbidden',
        'returned error: 403',
        'Permission to .* denied',
        'Repository not found',
        'fatal: Authentication',
        'GCM_INTERACTIVE'
    )
    foreach ($p in $patterns) { if ($text -match $p) { return $true } }
    return $false
}
function Show-AuthHelp {
    Write-Host ""
    Write-Host "[AUTH] git could not get a credential WITHOUT asking (silent mode)." -ForegroundColor Red
    Write-Host "       (this is the same thing the watcher sees - it can never click anything)" -ForegroundColor DarkGray
    Write-Host "       fix it once, then pushes never pop a window again:" -ForegroundColor Yellow
    Write-Host "         .\auth.ps1 -Setup      # GitHub CLI > Git Credential Manager (dpapi)" -ForegroundColor Yellow
    Write-Host "         .\auth.ps1 -Verify     # prove it with prompts disabled" -ForegroundColor Yellow
    Write-Host "       or do ONE interactive login (then it never asks again):" -ForegroundColor Yellow
    Write-Host "         gh auth login                          # device code, no window to click" -ForegroundColor Yellow
    Write-Host "         .\push.ps1 -Prompt \"msg\"               # or let the login window appear once" -ForegroundColor Yellow
    Write-Host "       (the watcher cannot show a window at all - it needs the silent path)" -ForegroundColor Yellow
    Write-Host "       BUT '403 ... Permission to OWNER/REPO denied to OTHER-USER' is not a" -ForegroundColor Yellow
    Write-Host "       login problem - the credential works, that ACCOUNT cannot write here:" -ForegroundColor Yellow
    Write-Host "         .\auth.ps1 -Accounts             # which gh login can push to this repo" -ForegroundColor Yellow
    Write-Host "         .\auth.ps1 -Account <login>     # pin THIS clone to it (others keep the default)" -ForegroundColor Yellow
}

# git refuses to commit without an identity; set a local one if missing
if (-not (git config user.name)) {
    git config user.name  'mqgg5630-cyber'
    git config user.email 'mqgg5630-cyber@users.noreply.github.com'
    Write-Host "== set a default git identity for this repo (change it with git config user.name)" -ForegroundColor Yellow
}

Write-Host "== repo  : $repo" -ForegroundColor Cyan
Write-Host "== branch: $Branch" -ForegroundColor Cyan
if ($noPrompt) { Write-Host "== mode  : silent (prompts disabled - no window can appear)" -ForegroundColor Cyan }
else           { Write-Host "== mode  : interactive (-Prompt; git may ask for credentials)" -ForegroundColor Yellow }

# Get the server side first so the push cannot be rejected as non-fast-forward
$rc = GitRun @('fetch', $Remote)
if ($rc -ne 0) { Write-Host "[ERROR] git fetch failed (network? see .\doctor.ps1)" -ForegroundColor Red; exit 3 }
$rc = GitRun @('checkout', $Branch)
if ($rc -ne 0) { Write-Host "[ERROR] git checkout $Branch failed (unknown branch in this clone?)" -ForegroundColor Red; exit 3 }
$pullOut = GitOut @('pull', '--ff-only', $Remote, $Branch)
if ($pullOut.text) { Write-Host $pullOut.text }
if ($pullOut.code -ne 0) {
    # A failed push leaves this repo's own "verdict" commits behind, and the
    # branch then diverges from the remote - which would stall the watcher on
    # every later round (field report 2026-09-15: watchdog exits 3, forever).
    # Those commits are regenerable, so drop them (keeping the files) and try
    # the fast-forward once more.
    $onlyArtifacts = $false
    try {
        $ahead = @(((GitOut @('log', '--format=%s', ("{0}..HEAD" -f "$Remote/$Branch"))).text) -split "`r?`n" | Where-Object { $_ -match '\S' })
        if ($ahead.Count -gt 0) {
            $onlyArtifacts = $true
            foreach ($subj in $ahead) {
                if ($subj -notmatch '^(check: round|watch: local check artifacts)') { $onlyArtifacts = $false; break }
            }
        }
    } catch { $onlyArtifacts = $false }
    if ($onlyArtifacts) {
        Write-Host "== local commits are only watcher verdicts - realigning with the remote (files are kept)" -ForegroundColor Cyan
        $null = GitRun @('reset', '--mixed', "$Remote/$Branch")
        $deleted = @(((GitOut @('ls-files', '-d')).text) -split "`r?`n" | Where-Object { $_ -match '\S' })
        foreach ($d in $deleted) { if ($d) { $null = GitRun @('checkout', '--', $d) } }
        $pullOut = GitOut @('pull', '--ff-only', $Remote, $Branch)
        if ($pullOut.text) { Write-Host $pullOut.text }
    }
}
if ($pullOut.code -ne 0) {
    Write-Host "[ERROR] pull --ff-only failed - the local branch has diverged from $Remote/$Branch." -ForegroundColor Red
    Write-Host "        run .\doctor.ps1 -Fix (it stashes, re-points the branch and pulls)." -ForegroundColor Yellow
    if (Test-AuthFailure $pullOut.text) { Show-AuthHelp }
    exit 3
}

$null = GitRun @('add', '-A')
$st = GitOut @('status', '--porcelain')
if (-not $st.text) {
    Write-Host ""
    Write-Host "== nothing new to commit. done." -ForegroundColor Green
    exit 0
}

# optional: run the repo gate before committing, so a broken change (e.g. a
# .ps1 with non-ASCII bytes) can never reach the remote from this side either
if ($Gate) {
    $gateCmd = ''
    if ($cfgPath -and $cfg -and $cfg.gate) { $gateCmd = [string]$cfg.gate }
    if (-not $gateCmd) { $gateCmd = 'bash code/check_all.sh' }
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] -Gate needs bash on PATH (it ships with Git for Windows)" -ForegroundColor Red
        exit 1
    }
    Write-Host "== gate: $gateCmd" -ForegroundColor Cyan
    bash -c $gateCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[GATE FAILED] nothing was committed. Fix the checks first (or drop -Gate to skip)." -ForegroundColor Red
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = "sync: local update " + (Get-Date -Format 'yyyy-MM-dd HH:mm')
}

Write-Host ""
Write-Host "== files to be committed:" -ForegroundColor Cyan
Write-Host $st.text

$rc = GitRun @('commit', '-m', $Message)
if ($rc -ne 0) { Write-Host "[ERROR] commit failed." -ForegroundColor Red; exit 1 }

# the push itself: capture the output so the failure can be classified, then
# show it unchanged (the user should see exactly what git said)
$pushOut = GitOut @('push', $Remote, $Branch)
if ($pushOut.text) { Write-Host $pushOut.text }
if ($pushOut.code -ne 0) {
    Write-Host ""
    if (Test-AuthFailure $pushOut.text) {
        Show-AuthHelp
        exit 4
    }
    Write-Host "[ERROR] push failed." -ForegroundColor Red
    Write-Host "  * 'rejected': the remote branch moved. Run .\sync.ps1 first." -ForegroundColor Yellow
    if ($pushOut.text -match 'Could not resolve host|Failed to connect|Connection (timed out|refused)|unable to access|operation timed out|proxy') {
        Write-Host "  * this looks like a NETWORK/proxy problem, not a credential problem:" -ForegroundColor Yellow
        Write-Host "      git config --global --get http.proxy     # git's proxy (git uses it)" -ForegroundColor Yellow
        Write-Host "      echo \$env:HTTPS_PROXY                    # gh/other tools need THIS one" -ForegroundColor Yellow
        Write-Host "      .\auth.ps1 -Setup -PromptToken           # store a PAT offline (no API call)" -ForegroundColor Yellow
    } else {
        Write-Host "  * retry, or check .\doctor.ps1." -ForegroundColor Yellow
    }
    exit 1
}

Write-Host ""
Write-Host "== pushed to $Branch :" -ForegroundColor Green
$null = GitShow @('log', '-1', '--oneline', '--decorate')
exit 0
