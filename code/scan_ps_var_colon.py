#!/usr/bin/env python3
# scan_ps_var_colon.py - gate helper: find "$var:" inside .ps1 files.
#
# PowerShell parses a script file BEFORE running any of it, and "$round:" is
# parsed as a drive-qualified variable name -> ParserError -> nothing runs at
# all. That is how a 5-line logging change silently killed the whole watcher
# (2026-09-15). Scopes/drives that are legal are allow-listed; everything else
# must be written "${var}:".
import re, sys, glob, os

SAFE = {'env', 'global', 'script', 'local', 'private', 'using', 'variable',
        'function', 'alias', 'cert', 'wsman', 'hkcu', 'hklm'}
PAT = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*):')


def main():
    # works from the repo root (gate) or from code/ (by hand)
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    if os.path.isdir(os.path.join(root, '.git')) or os.path.isdir(os.path.join(here, '.git')):
        os.chdir(root)
    bad = 0
    for path in sorted(glob.glob('**/*.ps1', recursive=True)):
        if path.startswith('.git' + os.sep):
            continue
        for i, line in enumerate(open(path, encoding='utf-8', errors='replace').read().split('\n'), 1):
            if line.lstrip().startswith('#'):
                continue
            for m in PAT.finditer(line):
                if m.group(1).lower() in SAFE:
                    continue
                print('[FAIL] %s:%d: "$%s:" - write "${%s}:" instead' % (path, i, m.group(1), m.group(1)))
                bad = 1
    return bad


if __name__ == '__main__':
    sys.exit(main())
