#!/usr/bin/env python3
# check_loop_summary.py - gate helper: prove that EVERY exit path of the
# watcher's poll functions records a closing line before it returns.
#
# Why this exists: a poll that ends without printing anything leaves the
# console sitting on whatever the previous line was, which reads as "stuck"
# (field question 2026-09-16: "why does it stay on 'verdict pushed'?").
# v2.6.8 therefore requires every exit of Invoke-PollRound / Invoke-PollOnce
# to set $script:PollSummary, which the loop and the manual poll then print.
# Checking it statically means the rule cannot silently rot the next time
# somebody adds a `return`.
#
# Usage:  python code/check_loop_summary.py [path-to-watch.ps1]
#         (default: watch.ps1 in the current directory)
# Exit 0 = ok, 1 = failed.
#
# Negative self-test (must exit 1): delete any one
#   $script:PollSummary = ...
# line from watch.ps1 and re-run, or run it against a file with < 5 exits.
import io
import re
import sys

MIN_EXITS = 5

# wording the user already knows - if any of these disappears from watch.ps1
# the closing lines have been rewritten behind their back
REQUIRED_PHRASES = [
    'another poll is still running',
    'poll CRASHED',
    'verdict pushed back to',
    'next poll at',
]

SUMMARY_ASSIGN = re.compile(r'\$script:PollSummary\s*=[^=]')
RETURN_STMT = re.compile(r'(^|[;{]\s*)return\b')
# PowerShell function names may contain '-' (Invoke-PollRound), so the class
# must include it or the captured name stops at "Invoke"
FUNC_START = re.compile(r'^\s*function\s+([A-Za-z0-9_-]+)\b')


def read_lines(path):
    with io.open(path, encoding='utf-8', errors='replace') as fh:
        return [ln.rstrip('\r') for ln in fh.read().split('\n')]


def function_body(lines, name):
    """Locate `function <name> { ... }` and return (start, body, body_offset).

    The closing brace is the next line that is exactly "}" in column 0 - every
    inner brace in this codebase is indented, so this is unambiguous and does
    not need a string-aware brace counter.
    """
    start = None
    for i, ln in enumerate(lines):
        m = FUNC_START.match(ln)
        if m and m.group(1) == name:
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        if lines[j] == '}':
            return (start, lines[start + 1:j], start + 2)
    return None


def exit_paths(body):
    """[(index_in_body, text)] for every `return` statement, comments ignored."""
    out = []
    for k, ln in enumerate(body):
        stripped = ln.lstrip()
        if stripped.startswith('#'):
            continue
        if RETURN_STMT.search(stripped):
            out.append((k, stripped))
    return out


def audit(lines, name):
    """Return (exit_count, [(file_lineno, text), ...] of uncovered exits)."""
    found = function_body(lines, name)
    if found is None:
        return None
    _, body, offset = found
    bad = []
    prev = -1
    for (k, text) in exit_paths(body):
        window = body[prev + 1:k + 1]
        covered = any(SUMMARY_ASSIGN.search(w) and not w.lstrip().startswith('#')
                      for w in window)
        if not covered:
            bad.append((offset + k, text))
        prev = k
    return (len(exit_paths(body)), bad, body)


def main(argv):
    path = argv[1] if len(argv) > 1 else 'watch.ps1'
    try:
        lines = read_lines(path)
    except IOError as exc:
        print('[FAIL] cannot read %s: %s' % (path, exc))
        return 1
    text = '\n'.join(lines)
    fail = 0

    for phrase in REQUIRED_PHRASES:
        if phrase not in text:
            print('[FAIL] %s: required closing-line wording is gone: "%s"'
                  % (path, phrase))
            fail = 1

    res = audit(lines, 'Invoke-PollRound')
    if res is None:
        print('[FAIL] %s: function Invoke-PollRound not found' % path)
        return 1
    count, bad, _ = res
    print('== exits in Invoke-PollRound: %d' % count)
    if count < MIN_EXITS:
        print('[FAIL] only %d exit path(s) found, expected at least %d - the '
              'checker and watch.ps1 have drifted apart' % (count, MIN_EXITS))
        fail = 1
    for (lineno, body_text) in bad:
        print('[FAIL] %s:%d: exit does not set $script:PollSummary first: %s'
              % (path, lineno, body_text))
        fail = 1
    if not bad and count >= MIN_EXITS:
        print('OK: every exit path sets its closing summary')

    res2 = audit(lines, 'Invoke-PollOnce')
    if res2 is None:
        print('[FAIL] %s: function Invoke-PollOnce not found' % path)
        return 1
    count2, bad2, body2 = res2
    for (lineno, body_text) in bad2:
        print('[FAIL] %s:%d: exit does not set $script:PollSummary first: %s'
              % (path, lineno, body_text))
        fail = 1
    once_text = '\n'.join(body2)
    for phrase in ('another poll is still running', 'poll CRASHED'):
        if phrase not in once_text:
            print('[FAIL] Invoke-PollOnce no longer records "%s"' % phrase)
            fail = 1
    print('== exits in Invoke-PollOnce: %d (lock held / crashed / normal)' % count2)

    if fail:
        return 1
    print('OK: loop closing lines covered (%d exit paths, all with their own summary)'
          % count)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
