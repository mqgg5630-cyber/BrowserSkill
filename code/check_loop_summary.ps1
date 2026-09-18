# check_loop_summary.ps1 - local twin of code/check_loop_summary.py.
#
# Proves that EVERY exit path of watch.ps1's Invoke-PollRound /
# Invoke-PollOnce records a closing line ($script:PollSummary) before it
# returns. A poll that ends silently leaves the console sitting on the
# previous line, which reads as "stuck" (field question 2026-09-16), so v2.6.8
# prints a summary on every exit - this file keeps that rule from rotting.
#
# Usage:
#     .\code\check_loop_summary.ps1
#     .\code\check_loop_summary.ps1 -WatchPath .\watch.ps1
#
# Negative self-test (must exit 1): delete any one
#     $script:PollSummary = ...
# line from watch.ps1 and re-run.
#
# Exit 0 = ok, 1 = failed.
#
# ASCII-only on purpose (Windows PowerShell 5.1 decodes .ps1 as ANSI/GBK).

param(
    [string]$WatchPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $WatchPath) {
    $guess = Join-Path $PSScriptRoot '..\watch.ps1'
    if (Test-Path -LiteralPath $guess) { $WatchPath = $guess } else { $WatchPath = '.\watch.ps1' }
}

if (-not (Test-Path -LiteralPath $WatchPath)) {
    Write-Output ('[FAIL] cannot read ' + $WatchPath)
    exit 1
}

$lines = @(Get-Content -LiteralPath $WatchPath -Encoding UTF8)
$text  = ($lines -join "`n")
$fail  = 0

# wording the user already knows - losing any of these means the closing lines
# were rewritten behind their back
$required = @('another poll is still running', 'poll CRASHED', 'verdict pushed back to', 'next poll at')
foreach ($p in $required) {
    if ($text.IndexOf($p, [StringComparison]::Ordinal) -lt 0) {
        Write-Output ('[FAIL] ' + $WatchPath + ': required closing-line wording is gone: "' + $p + '"')
        $fail = 1
    }
}

# `function <name> { ... }` - the closing brace is the next line that is
# exactly "}" in column 0 (every inner brace in this codebase is indented)
function Get-FunctionBody {
    param($All, [string]$Name)
    $start = -1
    for ($i = 0; $i -lt $All.Count; $i++) {
        if ($All[$i] -match ('^\s*function\s+' + [regex]::Escape($Name) + '\b')) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    for ($j = $start + 1; $j -lt $All.Count; $j++) {
        if ($All[$j] -eq '}') {
            if ($j -le ($start + 1)) { $body = @() } else { $body = @($All[($start + 1)..($j - 1)]) }
            return @{ body = $body; offset = ($start + 2) }
        }
    }
    return $null
}

# count the `return` statements and flag the ones with no summary before them
function Test-Exits {
    param($All, [string]$Name)
    $fn = Get-FunctionBody -All $All -Name $Name
    if (-not $fn) { return $null }
    $body = @($fn.body)
    $bad  = @()
    $prev = -1
    $n    = 0
    for ($k = 0; $k -lt $body.Count; $k++) {
        $s = $body[$k].TrimStart()
        if ($s.StartsWith('#')) { continue }
        if ($s -notmatch '(^|[;{]\s*)return\b') { continue }
        $n++
        $covered = $false
        for ($w = ($prev + 1); $w -le $k; $w++) {
            $wl = $body[$w].TrimStart()
            if ($wl.StartsWith('#')) { continue }
            if ($wl -match '\$script:PollSummary\s*=[^=]') { $covered = $true; break }
        }
        if (-not $covered) { $bad += (('{0}: {1}' -f ($fn.offset + $k), $s)) }
        $prev = $k
    }
    return @{ count = $n; bad = $bad; bodyText = ($body -join "`n") }
}

$res = Test-Exits -All $lines -Name 'Invoke-PollRound'
if (-not $res) {
    Write-Output ('[FAIL] ' + $WatchPath + ': function Invoke-PollRound not found')
    exit 1
}
Write-Output ('== exits in Invoke-PollRound: ' + $res.count)
if ($res.count -lt 5) {
    Write-Output ('[FAIL] only ' + $res.count + ' exit path(s) found, expected at least 5 - the checker and watch.ps1 have drifted apart')
    $fail = 1
}
foreach ($b in $res.bad) {
    Write-Output ('[FAIL] ' + $WatchPath + ':' + $b + ' - exit does not set $script:PollSummary first')
    $fail = 1
}
if ($res.bad.Count -eq 0 -and $res.count -ge 5) {
    Write-Output 'OK: every exit path sets its closing summary'
}

$res2 = Test-Exits -All $lines -Name 'Invoke-PollOnce'
if (-not $res2) {
    Write-Output ('[FAIL] ' + $WatchPath + ': function Invoke-PollOnce not found')
    exit 1
}
foreach ($b in $res2.bad) {
    Write-Output ('[FAIL] ' + $WatchPath + ':' + $b + ' - exit does not set $script:PollSummary first')
    $fail = 1
}
foreach ($p in @('another poll is still running', 'poll CRASHED')) {
    if ($res2.bodyText.IndexOf($p, [StringComparison]::Ordinal) -lt 0) {
        Write-Output ('[FAIL] Invoke-PollOnce no longer records "' + $p + '"')
        $fail = 1
    }
}
Write-Output ('== exits in Invoke-PollOnce: ' + $res2.count + ' (lock held / crashed / normal)')

if ($fail -ne 0) {
    Write-Output '== check_loop_summary FAILED'
    exit 1
}
Write-Output ('OK: loop closing lines covered (' + $res.count + ' exit paths, all with their own summary)')
Write-Output '== check_loop_summary PASSED'
exit 0
