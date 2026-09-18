# auth.ps1 - make git authentication on this machine NON-INTERACTIVE
#            (no popup window, no click) so an unattended push always works.
#
# Why this exists: the git-sync watcher (watch.ps1) pushes its verdict from a
# scheduled task. If git has to ASK for a credential there, the poll either
# hangs waiting for your click or dies - and the whole auto-verification loop
# looks broken. This script inspects / configures / PROVES the credential path:
#
#   * LOOK FIRST        probe with the CURRENT configuration (prompts disabled).
#                       If a credential already answers, nothing is changed -
#                       v2.5.1 lesson: switching the store on a machine that
#                       already had a working credential in Windows Credential
#                       Manager made that credential INVISIBLE.
#   * GitHub CLI        'gh auth setup-git' keeps the token in gh's own config
#                       file and registers gh as git's credential helper.
#   * GCM + a store     Git Credential Manager (ships with Git for Windows).
#                       wincredman (the default) needs an interactive desktop;
#                       dpapi files also work from session 0 - see -MigrateStore.
#   * a token           -Token / -TokenFile / -PromptToken seeds the store with
#                       no browser round-trip at all.
#
# Usage (inside the repo folder):
#     .\auth.ps1                      # report: how would a push authenticate NOW?
#     .\auth.ps1 -Setup               # look, fix only if needed, then verify
#     .\auth.ps1 -Verify              # prove it: prompts OFF, ls-remote + push --dry-run
#     .\auth.ps1 -Verify -Quick       # only ls-remote (skip the push dry-run)
#     .\auth.ps1 -Setup -TokenFile C:\secrets\gh_pat.txt
#     .\auth.ps1 -MigrateStore        # copy the credential into dpapi (needed for
#                                     #   .\watch.ps1 -Register -Headless / S4U)
#     .\auth.ps1 -GhLogin             # do the ONE interactive login for you
#                                     #   (gh device code -> gh becomes the helper)
#     .\auth.ps1 -GhLogin -HttpProxy http://127.0.0.1:7890   # behind a proxy
#     .\auth.ps1 -Setup -PromptToken  # PAT route - works with NO api access at setup
#     .\auth.ps1 -Json -Verify        # machine readable (doctor + the local check read this)
#     .\auth.ps1 -Unset               # undo what -Setup changed (keeps credentials)
#
# MULTI-ACCOUNT (one machine, several GitHub logins):
#     .\auth.ps1 -Accounts            # every gh login + who can push to THIS repo
#                                     #   (the 403 diagnosis: "the credential is
#                                     #    fine, that account cannot write here")
#     .\auth.ps1 -Account <login>     # pin THIS clone to one gh account; other
#                                     #   clones keep the machine default
#     .\auth.ps1 -Unpin               # drop the pin (machine default again)
#
# Nothing here ever prints the token. Exit codes: 0 ready / verified, 1 not ready.
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).
# NB: inside a double-quoted string write "${name}:" - a bare "$name:" parses as
# a drive-qualified variable and kills the whole file at parse time.

param(
    [switch]$Setup,
    [switch]$Verify,
    [switch]$Quick,
    [switch]$Json,
    [switch]$Unset,
    [switch]$MigrateStore,
    [switch]$GhLogin,
    [string]$HttpProxy = '',
    [switch]$PreferDpapi,
    [switch]$SkipVerify,
    [string]$Store = '',
    [string]$Token = '',
    [string]$TokenFile = '',
    [switch]$PromptToken,
    [switch]$Accounts,
    [string]$Account = '',
    [switch]$Unpin,
    [string]$Config = '',
    [string]$Remote = ''
)

$ErrorActionPreference = 'Continue'

# Prompts OFF for this whole script: it exists to find out whether git can get
# a credential WITHOUT asking, so every call it makes must be unable to ask.
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE     = 'never'
$env:GH_PROMPT_DISABLED  = '1'
$env:GIT_ASKPASS         = ''
$env:SSH_ASKPASS         = ''

# repo root = walk up from this script until .git appears, so the script also
# works when run straight from skills\git-sync\scripts\
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    $up = Split-Path -Parent $repo
    if (-not $up -or $up -eq $repo) { break }
    $repo = $up
}
Set-Location -LiteralPath $repo

function Say([string]$text, [string]$color = 'Gray') {
    if ($Json) { return }
    Write-Host $text -ForegroundColor $color
}
function Ok([string]$text)   { Say "  [ok]   $text" 'Green' }
function Warn([string]$text) { Say "  [warn] $text" 'Yellow' }
function Bad([string]$text)  { Say "  [FAIL] $text" 'Red' }
function Note([string]$text) { Say "  [info] $text" }
function Brief([string]$text, [int]$lines = 3) {
    return (($text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First $lines) -join ' | ')
}

$notes   = New-Object System.Collections.ArrayList
$changed = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------- proxy
# git may reach GitHub through a proxy configured in git config (http.proxy)
# while gh only honours HTTPS_PROXY/HTTP_PROXY - a very common reason why
# "git fetch works but gh auth login times out". Detect both and apply them to
# everything this script starts.
function Get-GitProxy {
    foreach ($k in @('http.proxy', 'https.proxy')) {
        $v = (git config --get $k 2>$null | Out-String).Trim()
        if ($v) { return $v }
    }
    return ''
}
$proxyFrom = ''
$proxyUrl = $HttpProxy
if (-not $proxyUrl) {
    $gp = Get-GitProxy
    if ($gp) { $proxyUrl = $gp; $proxyFrom = 'git config http.proxy' }
}
if (-not $proxyUrl -and ($env:HTTPS_PROXY -or $env:HTTP_PROXY)) {
    $proxyUrl = $(if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { $env:HTTP_PROXY })
    $proxyFrom = 'environment'
}
if ($proxyUrl) {
    if (-not $proxyFrom) { $proxyFrom = '-HttpProxy' }
    $env:HTTPS_PROXY = $proxyUrl
    $env:HTTP_PROXY  = $proxyUrl
    $env:ALL_PROXY   = $proxyUrl
}

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

$Branch = ''
if ($cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($cfg.branch) { $Branch = [string]$cfg.branch }
    if (-not $Remote -and $cfg.remote) { $Remote = [string]$cfg.remote }
}
if (-not $Remote) { $Remote = 'origin' }

# --------------------------------------------------------------- primitives
# Every external call goes through cmd with 2>&1 INSIDE cmd. Reason: PS 5.1
# turns a native command's stderr into a NativeCommandError that it prints in
# red at the call site even when the call redirects 2>&1 - ugly and confusing
# when the "error" is just GCM explaining that it wanted to prompt.
function QuoteArg([string]$a) {
    # an EMPTY argument must still be passed on (git config key "" is the
    # documented way to RESET the credential helper list - dropping it would
    # silently turn the write into a read)
    if ($a -eq '') { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '""') + '"' }
    return $a
}
function RunLine([string]$line) {
    $out = & $env:ComSpec /c ($line + ' 2>&1')
    return @{ code = $LASTEXITCODE; text = (($out | Out-String).TrimEnd()) }
}
function RunExe([string]$exe, [string[]]$exeArgs) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        return @{ code = 127; text = "(not found: $exe)" }
    }
    $parts = @($exe) + @($exeArgs | ForEach-Object { QuoteArg $_ })
    return RunLine (($parts) -join ' ')
}
# git call with prompts disabled; optional credential-store override and an
# optional file fed to stdin (used by the credential probe)
function GitG([string[]]$gitArgs, [string]$UseStore = '', [string]$StdinFile = '') {
    $parts = @('git', '-c', 'credential.interactive=false', '-c', 'core.askpass=')
    if ($UseStore) { $parts += @('-c', ('credential.credentialStore=' + $UseStore)) }
    $parts += $gitArgs
    $line = (($parts | ForEach-Object { QuoteArg $_ }) -join ' ')
    if ($StdinFile) { $line = $line + ' < "' + $StdinFile + '"' }
    return RunLine $line
}
function CfgGet([string]$key) {
    $r = GitG @('config', '--get', $key)
    if ($r.code -ne 0) { return '' }
    return $r.text.Trim()
}
function CfgSet([string]$key, [string]$value) {
    $r = GitG @('config', '--global', $key, $value)
    return ($r.code -eq 0)
}
function CfgUnset([string]$key) {
    $r = GitG @('config', '--global', '--unset', $key)
    return ($r.code -eq 0)
}

if (-not $Branch) { $Branch = (GitG @('rev-parse', '--abbrev-ref', 'HEAD')).text }

# ------------------------------------------------------------ remote + host
$remoteUrl = (GitG @('remote', 'get-url', $Remote)).text
$hostName  = ''
if     ($remoteUrl -match '^https?://([^/]+)')      { $hostName = $Matches[1] }
elseif ($remoteUrl -match '^ssh://[^@]*@?([^/:]+)') { $hostName = $Matches[1] }
elseif ($remoteUrl -match '^[^@]+@([^:]+):')        { $hostName = $Matches[1] }
if (-not $hostName) { $hostName = 'github.com' }
$scheme = 'other'
if     ($remoteUrl -match '^https?://')     { $scheme = 'https' }
elseif ($remoteUrl -match '^ssh://|^git@')  { $scheme = 'ssh' }

# ------------------------------------------------------------- environment
$gitVer   = (RunExe 'git' @('--version')).text
$psVer    = $PSVersionTable.PSVersion.ToString()
$gcmVer   = ''
$r = RunExe 'git' @('credential-manager', '--version')
if ($r.code -eq 0) { $gcmVer = ($r.text -split "`n")[0].Trim() }
if (-not $gcmVer) {
    $r = RunExe 'git-credential-manager' @('--version')
    if ($r.code -eq 0) { $gcmVer = ($r.text -split "`n")[0].Trim() }
}
$ghVer = ''
$r = RunExe 'gh' @('--version')
if ($r.code -eq 0) { $ghVer = ($r.text -split "`n")[0].Trim() }
$ghUser = ''; $ghState = 'not installed'
if ($ghVer) {
    $st = RunExe 'gh' @('auth', 'status', '--hostname', $hostName)
    if ($st.code -eq 0) {
        $ghState = 'logged in'
        if     ($st.text -match '(?m)account\s+(\S+)') { $ghUser = $Matches[1] }
        elseif ($st.text -match '(?m)as\s+(\S+)')      { $ghUser = $Matches[1] }
    } else {
        $ghState = 'present, NOT logged in'
    }
}

function Get-ConfigState {
    return @{
        helper   = (CfgGet 'credential.helper')
        hostHelp = (CfgGet ("credential.https://$hostName.helper"))
        store    = (CfgGet 'credential.credentialStore')
        inter    = (CfgGet 'credential.interactive')
    }
}
$cfgState = Get-ConfigState

# ------------------------------------------------------- credential probing
# The only honest question is "can git get a credential without asking?", so we
# ask it exactly the way the watcher will - prompts off, nothing can appear.
# The password is never printed; only its length and the user name show up.
function Invoke-CredProbe([string]$UseStore = '') {
    if ($scheme -ne 'https') { return @{ ok = $false; user = ''; pass = ''; detail = 'skipped (remote is not https)' } }
    $reqFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($reqFile, "protocol=https`nhost=$hostName`n`n", (New-Object System.Text.UTF8Encoding($false)))
        $p = GitG @('credential', 'fill') $UseStore $reqFile
        $user = ''; $pass = ''
        if ($p.text -match '(?m)^username=(.*)$') { $user = $Matches[1].Trim() }
        if ($p.text -match '(?m)^password=(.*)$') { $pass = $Matches[1].Trim() }
        if ($pass) {
            return @{ ok = $true; user = $user; pass = $pass; detail = "username=$user password=(hidden, $($pass.Length) chars)" }
        }
        $msg = Brief $p.text 3
        if (-not $msg) { $msg = '(the helper returned nothing)' }
        return @{ ok = $false; user = $user; pass = ''; detail = $msg }
    } finally {
        Remove-Item -LiteralPath $reqFile -Force -ErrorAction SilentlyContinue
    }
}
# write a credential into a specific store (migration/seed) - never printed
function Save-Cred([string]$User, [string]$Pass, [string]$IntoStore = '') {
    $reqFile = [System.IO.Path]::GetTempFileName()
    try {
        $body = "protocol=https`nhost=$hostName`nusername=$User`npassword=$Pass`n`n"
        [System.IO.File]::WriteAllText($reqFile, $body, (New-Object System.Text.UTF8Encoding($false)))
        $p = GitG @('credential', 'approve') $IntoStore $reqFile
        return ($p.code -eq 0)
    } finally {
        $body = $null
        Remove-Item -LiteralPath $reqFile -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------- multi-account support
# A machine often carries SEVERAL GitHub logins (gh can hold many, exactly one
# is "active"). A clone authenticates as the ACTIVE one - so when the repo
# belongs to a different account the credential is perfectly valid and the push
# still fails with 403 "Permission to OWNER/REPO.git denied to THE-OTHER-USER".
# Field case 2026-09-17 (LAPTOP-R77M5D6M): repo shaohuawen03-cyber/new, machine
# credential mqgg5630-cyber. Fix: pin THIS clone to one account through local
# git config; every other clone on the machine keeps the default.
function Get-RepoSlug {
    if (-not $remoteUrl) { return '' }
    if ($remoteUrl -match '[:/]([^/:]+)/([^/]+?)(\.git)?/?$') { return ($Matches[1] + '/' + $Matches[2]) }
    return ''
}
function Get-GhAccountInfo {
    # name + active flag per gh login (parses plain "gh auth status")
    $accs = New-Object System.Collections.ArrayList
    if (-not $ghVer) { return $accs }
    $r = RunExe 'gh' @('auth', 'status')
    $cur = $null
    foreach ($ln in ($r.text -split "`r?`n")) {
        if ($ln -match 'account\s+(\S+)') {
            $cur = @{ name = $Matches[1]; active = $false }
            $null = $accs.Add($cur)
        } elseif ($cur -and $ln -match 'Active account:\s*true') {
            $cur.active = $true
        }
    }
    return $accs
}
function Get-PinnedAccount {
    # a pin looks like: !GH_TOKEN=$(... 'gh.exe' auth token -u NAME) ... git-credential
    $r = GitG @('config', '--local', '--get-all', 'credential.helper')
    if ($r.code -ne 0) { return '' }
    foreach ($ln in ($r.text -split "`r?`n")) {
        if ($ln -match 'auth\s+token\s+-u\s+([^\s\)]+)') { return $Matches[1] }
    }
    return ''
}
function Test-GhAccount([string]$login) {
    if (-not $ghVer -or -not $login) { return $false }
    $r = RunExe 'gh' @('auth', 'token', '-u', $login)
    return ($r.code -eq 0 -and $r.text.Trim() -ne '')
}
function Test-AccountPush([string]$login) {
    # ask the API AS that account: .permissions.push answers the real question,
    # including for public repos where an anonymous read works just fine
    $slug = Get-RepoSlug
    if (-not $slug) { return 'unknown' }
    $old = $env:GH_TOKEN
    $t = RunExe 'gh' @('auth', 'token', '-u', $login)
    if ($t.code -ne 0) { return 'no-token' }
    $env:GH_TOKEN = $t.text.Trim()
    $r = RunExe 'gh' @('api', "repos/$slug", '--jq', '.permissions.push')
    if ($old) { $env:GH_TOKEN = $old } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
    if ($r.code -ne 0) { return 'unknown' }
    $val = (($r.text -split "`r?`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    if ($val -match '^true')  { return 'yes' }
    if ($val -match '^false') { return 'no' }
    return 'unknown'
}
function Test-LocalHelperReset {
    # the reset is in place when the FIRST local credential.helper entry is empty
    $r = GitG @('config', '--local', '--get-all', 'credential.helper')
    if ($r.code -ne 0) { return $false }
    $first = ($r.text -split "`r?`n", 2)[0]
    return ($first -eq '')
}
function Reset-LocalHelperList {
    # An EMPTY credential.helper value drops every helper collected so far -
    # the machine-level ones (GCM / gh's global helper = the ACTIVE account)
    # included. Without it a local pin changes nothing at all, because those
    # machine helpers are consulted FIRST and answer with the wrong account.
    #
    # Writing an EMPTY ARGUMENT is unreliable on Windows: cmd/MSYS can drop it,
    # then `git config key ""` degrades into a READ that exits 1 - exactly how
    # the first version of this feature failed in the field (2026-09-17,
    # "could not write the local pin:" with an empty detail). So try three
    # routes and verify after each one:
    #   argv  - git config --local --replace-all credential.helper ""
    #   stdin - git config --stdin (git >= 2.45), empty value line, no argv
    #   file  - insert the entry into .git/config by hand (always works)
    $null = GitG @('config', '--local', '--replace-all', 'credential.helper', '')
    if (Test-LocalHelperReset) { return 'argv' }

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, "credential.helper`n`n", (New-Object System.Text.UTF8Encoding($false)))
        $r = RunLine ('git config --local --stdin < "' + $tmp + '"')
        if ($r.code -eq 0 -and (Test-LocalHelperReset)) { return 'stdin' }
    } catch { } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    # last resort: edit the config text. The entry has to come FIRST in the
    # [credential] section - the reset only drops what git has already read.
    $cfgRel = (GitG @('rev-parse', '--git-path', 'config')).text.Trim()
    if (-not $cfgRel) { return '' }
    $cfgAbs = if ([System.IO.Path]::IsPathRooted($cfgRel)) { $cfgRel } else { Join-Path $repo $cfgRel }
    if (-not (Test-Path -LiteralPath $cfgAbs)) { return '' }
    try {
        $raw = [System.IO.File]::ReadAllText($cfgAbs)
        $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
        $out = New-Object System.Collections.ArrayList
        $done = $false
        foreach ($ln in ($raw -split "`r?`n")) {
            $null = $out.Add($ln)
            if (-not $done -and $ln -match '^\s*\[credential\]\s*$') {
                $null = $out.Add("`thelper = ")
                $done = $true
            }
        }
        if (-not $done) {
            $null = $out.Insert(0, '')
            $null = $out.Insert(0, "`thelper = ")
            $null = $out.Insert(0, '[credential]')
        }
        [System.IO.File]::WriteAllText($cfgAbs, ($out -join $nl), (New-Object System.Text.UTF8Encoding($false)))
        if (Test-LocalHelperReset) { return 'file' }
    } catch { }
    return ''
}

function Show-Accounts {
    $slug   = Get-RepoSlug
    $pinned = Get-PinnedAccount
    $info   = Get-GhAccountInfo
    $active = ''
    foreach ($a in $info) { if ($a.active) { $active = $a.name } }
    Say '== accounts (gh logins on this machine)' 'Cyan'
    if (-not $ghVer) {
        Say '   gh is not installed - the other route is .\auth.ps1 -Setup -PromptToken'
        Say ''
        return
    }
    Say ("   repo   : {0}" -f $(if ($slug) { $slug } else { "(cannot parse: $remoteUrl)" }))
    if ($info.Count -eq 0) {
        Say '   (no logged-in gh account - run gh auth login)'
        Say ''
        return
    }
    Say ("   active : {0}   <- the machine default, used by every clone" -f $active)
    foreach ($a in $info) {
        $tags = @()
        if ($a.active) { $tags += 'active' }
        if ($a.name -eq $pinned) { $tags += 'PINNED here' }
        $push = Test-AccountPush $a.name
        $pushTxt = 'unknown'
        if     ($push -eq 'yes')      { $pushTxt = 'can push to this repo' }
        elseif ($push -eq 'no')       { $pushTxt = 'CANNOT push here (403)' }
        elseif ($push -eq 'no-token') { $pushTxt = 'no token (gh auth login)' }
        Say ("   - {0,-24} {1,-18} {2}" -f $a.name, ($tags -join ','), $pushTxt)
    }
    Say '   pin THIS clone     : .\auth.ps1 -Account <login>'
    Say '   back to default    : .\auth.ps1 -Unpin'
    Say '   only this folder is pinned - every other clone keeps the default'
    Say ''
}

$probe = Invoke-CredProbe ''

# ------------------------------------------------------------------ unsets
if ($Unset) {
    Say '== auth.ps1 -Unset : reverting what -Setup may have changed' 'Cyan'
    foreach ($k in @('credential.credentialStore', 'credential.interactive', ("credential.https://$hostName.helper"))) {
        if (CfgUnset $k) { Ok "unset git config key: $k" } else { Note "nothing to unset: $k" }
    }
    Note 'stored credentials were NOT deleted'
    Say ''
    exit 0
}

# ---------------------------------------------------------------- gh login
if ($GhLogin) {
    if ($Json) {
        Write-Host '[ERROR] -GhLogin is interactive and cannot be combined with -Json' -ForegroundColor Red
        exit 1
    }
    if (-not $ghVer) {
        Bad 'gh is not installed - install it (winget install GitHub.cli) or use -PromptToken'
        exit 1
    }
    Say '== auth.ps1 -GhLogin : the ONE interactive step (device code / browser)' 'Cyan'
    Note "host: $hostName   protocol: https"
    Note 'if it asks, choose: GitHub.com -> HTTPS -> Login with a web browser'
    if ($proxyUrl) {
        Note "using proxy: $proxyUrl  (from $proxyFrom)"
    } else {
        Note 'no proxy detected. If this times out, GitHub is unreachable directly:'
        Note '   set one of these and retry - gh reads them, git may already have one:'
        Note '     .\auth.ps1 -GhLogin -HttpProxy http://127.0.0.1:7890'
        Note '     setx HTTPS_PROXY http://127.0.0.1:7890     (then reopen the console)'
    }
    Write-Host ''
    # run gh DIRECTLY (not captured): it prints a one-time code the user must
    # read, so its output has to stay visible on screen
    & gh auth login --hostname $hostName --git-protocol https --web
    $glCode = $LASTEXITCODE
    if ($glCode -ne 0) {
        Warn "gh auth login exited with $glCode"
        Note 'if the message was a timeout / connection failure, GitHub is not reachable'
        Note 'directly from this machine. Fix the network path first, then retry:'
        Note '   .\auth.ps1 -GhLogin -HttpProxy http://127.0.0.1:7890'
        Note '   or skip gh entirely and store a PAT offline (no API call at setup):'
        Note '   .\auth.ps1 -Setup -PromptToken'
        Note 'you can also run it yourself later:  gh auth login'
    } else {
        Ok 'gh login finished'
    }
    $ghState = 'unknown'
    $st = RunExe 'gh' @('auth', 'status', '--hostname', $hostName)
    if ($st.code -eq 0) {
        $ghState = 'logged in'
        if     ($st.text -match '(?m)account\s+(\S+)') { $ghUser = $Matches[1] }
        elseif ($st.text -match '(?m)as\s+(\S+)')      { $ghUser = $Matches[1] }
        $rr = RunExe 'gh' @('auth', 'setup-git', '--hostname', $hostName)
        if ($rr.code -eq 0) {
            Ok "gh is now git's credential helper for $hostName (no prompt, works in session 0 too)"
            $null = $changed.Add("credential.https://$hostName.helper = gh")
        } else {
            Warn "gh auth setup-git failed: $(Brief $rr.text 2)"
        }
    } else {
        Bad 'gh still reports "not logged in" - rerun it by hand:  gh auth login'
    }
    Say ''
    # fall through: the verify block below runs when -Verify is also given
    $Setup = $true
    $probe = Invoke-CredProbe ''
}

# ------------------------------------------------------- per-clone account pin
# The "two accounts on one machine" switch. It writes LOCAL git config of THIS
# clone only, so the machine default - and every other clone - is untouched:
# git-pull-arena keeps pushing as account A while this clone pushes as account B.
if ($Account -or $Unpin) {
    Say '== auth.ps1 account pin' 'Cyan'
    if ($scheme -ne 'https') {
        Bad "the remote is not https ($scheme) - a per-clone pin only applies to https"
        exit 1
    }
    if ($Unpin) {
        $any = $false
        foreach ($k in @('credential.helper', ("credential.https://$hostName.helper"))) {
            $r = GitG @('config', '--local', '--unset-all', $k)
            if ($r.code -eq 0) {
                Ok "removed the local pin: $k"
                $null = $changed.Add("$k (local) unset")
                $any = $true
            }
        }
        if (-not $any) { Note 'this clone had no local pin - nothing to undo' }
        Note 'the machine default is back in charge here (other clones were never touched)'
    } else {
        if (-not $ghVer) {
            Bad 'gh is not installed - install it (winget install GitHub.cli), or store a PAT with -Setup -PromptToken'
            exit 1
        }
        if (-not (Test-GhAccount $Account)) {
            Bad "gh has no usable account '$Account' (not logged in, or no token)"
            Note 'see the accounts:  .\auth.ps1 -Accounts'
            Note "add it first:     gh auth login    (then: .\auth.ps1 -Account $Account)"
            exit 1
        }
        # The helper command. git runs a '!'-helper as
        #     sh -c '<value> "$@"' '<value>' get
        # - it APPENDS "$@" - so the value has to be a function that is then
        # CALLED:
        #     !f() { ...; }; f    ->  f get             OK
        #     !if ...; fi         ->  if ...; fi get    SYNTAX ERROR
        # The second form shipped in v2.9.0 and never worked: git failed with
        # "syntax error near unexpected token `get'" (field case 2026-09-17).
        # Fail CLOSED on purpose: with no token for that account the helper exits
        # non-zero instead of handing out the ACTIVE account's token (an empty
        # GH_TOKEN makes gh fall back to the active account = the wrong user).
        # No double quotes anywhere (the value travels through cmd), forward
        # slashes in the path (works in both the Git shell and cmd).
        $ghExe = ''
        $gc = Get-Command gh -ErrorAction SilentlyContinue
        if ($gc -and $gc.Source) { $ghExe = [string]$gc.Source }
        $ghFwd = if ($ghExe) { $ghExe -replace '\\', '/' } else { 'gh' }
        $q = if ($ghExe) { "'" + $ghFwd + "'" } else { $ghFwd }
        $pin = '!f() { T=$(' + $q + ' auth token -u ' + $Account + ') || exit 1; GH_TOKEN=$T ' + $q + ' auth git-credential $@; }; f'

        $resetHow = Reset-LocalHelperList
        if (-not $resetHow) {
            Bad 'could not put the empty (resetting) entry into the local helper list'
            Note 'do it by hand and re-run -Account:'
            Note '   git config --local --replace-all credential.helper ""'
            exit 1
        }
        $r2 = GitG @('config', '--local', '--add', 'credential.helper', $pin)
        $listTxt = (GitG @('config', '--local', '--get-all', 'credential.helper')).text
        if ($r2.code -ne 0 -or -not $listTxt.Contains("auth token -u $Account")) {
            Bad "could not write the pin (exit $($r2.code))"
            if ($r2.text) { Note "git said: $(Brief $r2.text 2)" }
            Note ("local list now: " + (($listTxt -split "`r?`n") -join ' | '))
            exit 1
        }
        Ok "this clone now authenticates as '$Account' (empty reset via $resetHow + pin)"
        Note 'no fallback is added after the pin on purpose: if that account loses its'
        Note 'token the push FAILS instead of silently using the machine default'
        $null = $changed.Add("credential.helper (local) pinned to gh account $Account")
        $null = $notes.Add("account pin: $Account (reset via $resetHow)")
    }
    Say ''
    $probe = Invoke-CredProbe ''
    if ($probe.ok) {
        if (-not $Account) {
            # -Unpin: there is no account to compare against, the machine
            # default is the expected answer (v2.9.1 used to warn here with
            # "expected ''", which looked like a failure on a healthy machine)
            Ok "probe: the machine default answers again (username=$($probe.user))"
        } elseif ($probe.user -eq $Account -or $probe.user -eq 'x-access-token') {
            Ok "probe: the credential now comes from '$Account' (username=$($probe.user))"
        } else {
            Warn "probe returned username=$($probe.user) - expected '$Account' (still logged in?)"
        }
    } else {
        Warn "no credential after the change: $($probe.detail)"
    }
    if (-not $SkipVerify) { $Verify = $true }
    Say ''
}

# ------------------------------------------------------------------- setup
$migrated = ''
if ($Setup) {
    Say "== auth.ps1 -Setup  (repo: $repo)" 'Cyan'
    Say "   remote : $Remote -> $remoteUrl"
    Say "   branch : $Branch"
    Say ''
    $cfgState = Get-ConfigState

    if ($scheme -eq 'ssh') {
        Note 'the remote uses SSH - no credential helper is involved; the private'
        Note 'key must be reachable without a passphrase prompt (ssh-agent).'
        $ssh = RunExe 'ssh' @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-T', "git@$hostName")
        if ($ssh.text -match 'successfully authenticated') {
            Ok "ssh key accepted by $hostName in batch mode (no prompt)"
            $null = $notes.Add('ssh key works in batch mode')
        } else {
            Warn "ssh batch-mode probe said: $(Brief $ssh.text 2)"
            Note 'if an unattended push fails: enable ssh-agent or switch the remote to https'
            $null = $notes.Add('ssh key NOT proven in batch mode')
        }
        Say ''
        Say '== nothing else to do for SSH remotes.' 'Green'
        exit 0
    }

    # 1. a token was supplied -> seed it (never echoed anywhere)
    $seed = $Token
    if (-not $seed -and $TokenFile) {
        if (-not (Test-Path -LiteralPath $TokenFile)) { Bad "token file not found: $TokenFile"; exit 1 }
        $seed = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
    }
    if (-not $seed -and $PromptToken) {
        $sec = Read-Host -AsSecureString 'paste the GitHub token (input hidden)'
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try   { $seed = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ($seed) {
        # OFFLINE FIRST: writing the credential through the configured helper
        # needs no API call at all, so this works even when api.github.com is
        # unreachable (proxy/VPN not set up yet). gh's own store is tried next
        # because it also works from a session-0 task.
        $savedOffline = Save-Cred 'x-access-token' $seed $Store
        if ($savedOffline) {
            Ok 'token stored through the credential helper (offline - no API call needed)'
            $null = $changed.Add('credential stored in the helper (token)')
        }
        if ($ghVer) {
            $tmpTok = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tmpTok, $seed, (New-Object System.Text.UTF8Encoding($false)))
                $rr = RunLine ('gh auth login --hostname ' + $hostName + ' --git-protocol https --with-token < "' + $tmpTok + '"')
                if ($rr.code -eq 0) {
                    Ok "token also stored in gh's own config (works from session 0 too)"
                    $ghState = 'logged in'
                } else {
                    if (-not $savedOffline) { Warn "gh refused the token: $(Brief $rr.text 2)" }
                    else { Note 'gh could not store it too (network/API) - the helper copy is enough' }
                }
            } finally {
                Remove-Item -LiteralPath $tmpTok -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $savedOffline -and -not ($ghVer -and $ghState -eq 'logged in')) {
            Warn 'could not store the token (is a credential helper configured?)'
        }
        $seed = ''; $Token = ''
        $probe = Invoke-CredProbe ''
    }

    # 2. does the CURRENT configuration already work? then change nothing.
    if ($probe.ok -and -not $MigrateStore -and -not $PreferDpapi -and -not $Store) {
        Ok 'a credential already answers with prompts disabled - nothing to change'
        if ($cfgState.store -ne 'dpapi') {
            Note 'if you plan to run the watcher as S4U (.\watch.ps1 -Register -Headless),'
            Note 'that store is unreadable from session 0 - then run: .\auth.ps1 -MigrateStore'
        }
    } else {
        $done = $false

        # 3. gh as the helper (best: token lives in gh's own config file)
        if (-not $done -and $ghVer -and $ghState -eq 'logged in') {
            $rr = RunExe 'gh' @('auth', 'setup-git', '--hostname', $hostName)
            if ($rr.code -eq 0) {
                Ok "gh is now git's credential helper for $hostName (never prompts)"
                $null = $changed.Add("credential.https://$hostName.helper = gh")
                $p2 = Invoke-CredProbe ''
                if ($p2.ok) { $probe = $p2; $done = $true }
            } else {
                Warn "gh auth setup-git failed: $(Brief $rr.text 2)"
            }
        }

        # 4. find a store that already holds the credential, and keep it
        if (-not $done -and $gcmVer) {
            if (-not $cfgState.helper) {
                if (CfgSet 'credential.helper' 'manager') {
                    Ok 'credential.helper = manager (Git Credential Manager)'
                    $null = $changed.Add('credential.helper = manager')
                    $cfgState = Get-ConfigState
                }
            }
            $desired = $Store
            if (-not $desired -and ($MigrateStore -or $PreferDpapi)) { $desired = 'dpapi' }
            if ($desired) {
                $pWant = Invoke-CredProbe $desired
                if ($pWant.ok) {
                    Ok "credential found in the '$desired' store already"
                    $probe = $pWant
                    if ($cfgState.store -ne $desired) {
                        if (CfgSet 'credential.credentialStore' $desired) {
                            Ok "credential.credentialStore = $desired"
                            $null = $changed.Add("credential.credentialStore = $desired")
                        }
                    }
                    $done = $true
                }
            }
            if (-not $done) {
                foreach ($cand in @('dpapi', 'wincredman')) {
                    if ($desired -and $cand -eq $desired) { continue }
                    $pC = Invoke-CredProbe $cand
                    if ($pC.ok) {
                        Ok "found an existing credential in the '$cand' store"
                        $target = $desired
                        if (-not $target) { $target = $cand }
                        # Make the config agree with the store that actually works.
                        # wincredman IS the GCM default, so "unset" is the cleanest
                        # way to point at it (v2.5.0 switched this key to dpapi and
                        # hid a perfectly good wincredman credential - that was the
                        # bug this branch of the code exists to avoid).
                        if ($target -eq $cand -and $cfgState.store -ne $target) {
                            if ($cand -eq 'wincredman') {
                                if (CfgUnset 'credential.credentialStore') {
                                    Ok 'credential.credentialStore unset - back to the GCM default (wincredman), which holds the credential'
                                    $null = $changed.Add('credential.credentialStore unset (default wincredman)')
                                }
                            } elseif (CfgSet 'credential.credentialStore' $cand) {
                                Ok "credential.credentialStore = $cand"
                                $null = $changed.Add("credential.credentialStore = $cand")
                            }
                        }
                        if ($target -ne $cand) {
                            # copy it into the wanted store so -Headless/S4U works too
                            if (Save-Cred $pC.user $pC.pass $target) {
                                Ok "credential copied into the '$target' store"
                                $migrated = "$cand -> $target"
                                if (CfgSet 'credential.credentialStore' $target) {
                                    $null = $changed.Add("credential.credentialStore = $target")
                                }
                            } else {
                                Warn "could not copy the credential into '$target' - keeping '$cand'"
                            }
                        }
                        $p3 = Invoke-CredProbe ''
                        if ($p3.ok) { $probe = $p3; $done = $true }
                        break
                    }
                }
            }
            if (-not $done -and $desired -and -not $cfgState.store) {
                if (CfgSet 'credential.credentialStore' $desired) {
                    Note "credential.credentialStore = $desired (ready for a fresh login)"
                    $null = $changed.Add("credential.credentialStore = $desired")
                }
            }
        }

        # 5. still nothing -> say exactly what the one remaining click is
        if (-not $done -and -not $probe.ok) {
            if ($gcmVer) {
                Warn 'no usable credential yet - the helper WANTS TO ASK (that is the click you see)'
                Note 'GCM can explain itself (opens its own window):'
                Note '     git credential-manager diagnose'
            } else {
                Warn 'neither GitHub CLI nor Git Credential Manager found - install one first'
                $null = $notes.Add('no credential helper available')
            }
            Note 'pick ONE of these, once per machine:'
            Note '   gh auth login                          (browser/device code; needs gh)'
            Note '   .\auth.ps1 -Setup -PromptToken         (paste a PAT, hidden input)'
            Note '   .\auth.ps1 -Setup -TokenFile C:\pat.txt'
            Note '   .\push.ps1 -Prompt "msg"               (let the login window appear once)'
        }
    }
    Say ''
}

# ------------------------------------------------------------------ verify
$lsState = ''; $lsText = ''
$pushState = ''; $pushText = ''
if ($Verify -or ($Setup -and -not $SkipVerify)) {
    Say '== verify (every probe runs with prompts DISABLED: no window can appear)' 'Cyan'
    if ($scheme -ne 'https') {
        Note "remote is not https ($scheme) - verify manually: git push $Remote $Branch"
    } else {
        $r1 = GitG @('ls-remote', '--heads', $Remote)
        if ($r1.code -eq 0) {
            $lsState = 'passed'
            Ok "git ls-remote $Remote : passed (read access, no prompt)"
            Note 'a PUBLIC repo answers anonymous reads, so this line alone does not prove auth -'
            Note 'the push dry-run below is the one that counts' 
        } else {
            $lsState = 'failed'; $lsText = Brief $r1.text 3
            Bad "git ls-remote $Remote : failed - $lsText"
        }

        if (-not $Quick) {
            # A dry-run of HEAD:branch can be REJECTED as non-fast-forward when
            # the local tip is not a descendant of the remote - which says
            # nothing at all about the credential (field report 2026-09-15:
            # "failed to push some refs" was read as an auth failure while the
            # probe had just returned a valid token). So push a source ref that
            # is always acceptable:
            #   * the remote-tracking ref itself  -> a no-op push, and
            #   * a throwaway probe branch name   -> a "create", i.e. a ff.
            # --dry-run still authenticates and asks the server, so a success
            # proves write access; nothing is created on the remote.
            $srcRef = "refs/remotes/$Remote/$Branch"
            $dstRef = "refs/heads/$Branch-git-sync-probe"
            $hasTracking = (GitG @('rev-parse', '--verify', '--quiet', $srcRef)).code -eq 0
            if (-not $hasTracking) {
                $srcRef = 'HEAD'
                $dstRef = "refs/heads/$Branch"
                Note 'no remote-tracking ref yet - probing with HEAD (may report a rejection)'
            }
            $spec = $srcRef + ':' + $dstRef
            $r2 = GitG @('push', '--dry-run', $Remote, $spec)
            if ($r2.code -eq 0) {
                $pushState = 'passed'
                Ok ("git push --dry-run $Remote $spec : passed (write access, no prompt)")
            } elseif ($r2.text -match 'non-fast-forward|failed to push some refs|\[rejected\]|stale info') {
                # the server TALKED to us and refused the update - which means
                # the credential was accepted: this is not an auth problem
                $pushState = 'not-fast-forward'
                $pushText = Brief $r2.text 3
                Warn ("git push --dry-run : REJECTED (not a credential problem) - $pushText")
                Note 'the credential works; the ref you pushed was simply not a fast-forward.'
                Note 'run .\sync.ps1 to align with the remote, then push normally.'
            } else {
                $pushState = 'failed'; $pushText = Brief $r2.text 3
                Bad "git push --dry-run : failed - $pushText"
                if ($pushText -match '403|denied|Permission to') {
                    Note 'this is a PERMISSION problem, not a missing credential:'
                    Note 'the credential is valid, but THAT account cannot write to this repo.'
                    Note 'one machine can hold several logins - pick the one that owns the repo:'
                    Say ''
                    Show-Accounts
                }
            }
        } else {
            Note 'push dry-run skipped (-Quick)'
        }
    }
}

# refresh everything the report shows AFTER any change
$probe    = Invoke-CredProbe ''
$cfgState = Get-ConfigState

# ------------------------------------------------------------------ verdict
$ready = $probe.ok
if ($scheme -eq 'https') {
    if ($Verify -and -not $Quick) {
        # 'not-fast-forward' means the server refused the ref update AFTER
        # authenticating us - the credential is fine, so it counts as READY
        $ready = ($lsState -eq 'passed' -and $pushState -in @('passed', 'not-fast-forward'))
    }
    elseif ($Verify) { $ready = ($lsState -eq 'passed') }
    elseif ($Setup -and ($pushState -eq 'failed' -or $lsState -eq 'failed')) { $ready = $false }
} else {
    $ready = $true   # nothing to configure for ssh; the notes carry the caveat
}

if ($Json) {
    $skillVer = ''
    $verFile = Join-Path $repo 'skills\git-sync\VERSION'
    if (Test-Path -LiteralPath $verFile) { $skillVer = (Get-Content -LiteralPath $verFile -Raw).Trim() }
    $acctNames = @()
    $acctActive = ''
    foreach ($a in (Get-GhAccountInfo)) {
        $acctNames += $a.name
        if ($a.active) { $acctActive = $a.name }
    }
    $obj = [ordered]@{
        skill                  = $skillVer
        repo                   = $repo
        branch                 = $Branch
        remote                 = $Remote
        remote_url             = $remoteUrl
        scheme                 = $scheme
        host                   = $hostName
        git                    = $gitVer
        powershell             = $psVer
        proxy                  = $proxyUrl
        proxy_from             = $proxyFrom
        credential_helper      = $cfgState.helper
        host_helper            = $cfgState.hostHelp
        credential_store       = $cfgState.store
        credential_interactive = $cfgState.inter
        gcm                    = $gcmVer
        gh                     = $ghVer
        gh_state               = $ghState
        gh_user                = $ghUser
        accounts               = @($acctNames)
        active_account         = $acctActive
        pinned_account         = (Get-PinnedAccount)
        repo_slug              = (Get-RepoSlug)
        credential_available   = $probe.ok
        credential_detail      = $probe.detail
        migrated               = $migrated
        lsremote               = $lsState
        lsremote_detail        = $lsText
        push_dry_run           = $pushState
        push_dry_run_detail    = $pushText
        ready                  = [bool]$ready
        changed                = $changed.ToArray()
        notes                  = $notes.ToArray()
    }
    $obj | ConvertTo-Json -Depth 5 -Compress
    if ($ready) { exit 0 } else { exit 1 }
}

Say '== auth state' 'Cyan'
Say ("   repo    : {0}   branch: {1}   remote: {2} -> {3} [{4}]" -f $repo, $Branch, $Remote, $remoteUrl, $scheme)
Say ("   git     : {0}   PowerShell: {1}" -f $gitVer, $psVer)
Say ("   proxy   : {0}" -f $(if ($proxyUrl) { "$proxyUrl  [$proxyFrom]" } else { '(none detected - git config http.proxy / HTTPS_PROXY)' }))
$helperTxt = if ($cfgState.helper) { $cfgState.helper } else { '(none configured)' }
$storeTxt  = if ($cfgState.store)  { $cfgState.store }  else { '(default: wincredman / Windows Credential Manager)' }
$interTxt  = if ($cfgState.inter)  { $cfgState.inter }  else { '(unset)' }
$gcmTxt    = if ($gcmVer) { $gcmVer } else { '(not found)' }
$ghTxt     = if ($ghVer)  { "$ghVer [$ghState]$(if ($ghUser) { " user=$ghUser" })" } else { '(not installed)' }
Say ("   helper  : credential.helper = {0}" -f $helperTxt)
if ($cfgState.hostHelp) { Say ("             credential.helper for {0} = {1}" -f $hostName, $cfgState.hostHelp) }
Say ("             credential.credentialStore = {0}" -f $storeTxt)
Say ("             credential.interactive = {0}" -f $interTxt)
Say ("             Git Credential Manager = {0}" -f $gcmTxt)
Say ("             GitHub CLI = {0}" -f $ghTxt)
$pinnedAcc = Get-PinnedAccount
if ($pinnedAcc) { Say ("             account pin = {0}  (this clone only; local git config)" -f $pinnedAcc) }
if ($Accounts) { Say ''; Show-Accounts }
Say ''
$probeTxt = if ($probe.ok) { "OK - $($probe.detail)" } else { "NOT AVAILABLE - $($probe.detail)" }
Say ("   silent credential probe : {0}" -f $probeTxt)
if ($migrated) { Say ("   store migration         : {0}" -f $migrated) }
if ($lsState)   { Say ("   git ls-remote          : {0}" -f $lsState.ToUpper()) }
if ($pushState) { Say ("   push --dry-run         : {0}" -f $pushState.ToUpper()) }
Say ''

if ($scheme -eq 'ssh') {
    Say '== verdict: SSH remote - no helper needed; see the notes from -Setup.' 'Green'
    exit 0
}
if ($ready) {
    Say '== verdict: READY - a push completes with no window and no click.' 'Green'
    Say '   the watcher (watch.ps1) can push its results unattended.' 'Gray'
    if ($pushState -eq 'not-fast-forward') {
        Say '   (the dry-run was rejected only because the local ref was not a fast-forward -' 'Gray'
        Say '    run .\sync.ps1 and a real push will go through)' 'Gray'
    }
    exit 0
}
Say '== verdict: NOT READY - a push would need a human (or hang forever).' 'Red'
Say '   one login is unavoidable the FIRST time; after that it never asks again:' 'Yellow'
Say '     gh auth login                          # browser/device code (needs gh)' 'Yellow'
Say '     .\auth.ps1 -Setup -PromptToken         # paste a PAT with hidden input' 'Yellow'
Say '     .\auth.ps1 -Setup -TokenFile C:\pat.txt' 'Yellow'
Say '     .\push.ps1 -Prompt "msg"               # answer the login window once' 'Yellow'
Say '   then:  .\auth.ps1 -Verify   (prompts stay disabled in every probe)' 'Yellow'
if ($probe.detail) { Note "probe said: $($probe.detail)" }
exit 1
