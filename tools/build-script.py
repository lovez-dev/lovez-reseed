#!/usr/bin/env python3
"""Compile installer templates into Bash printf functions; no runtime Python."""
import argparse
import hashlib
import pathlib
import re
import shlex

ROOT = pathlib.Path(__file__).resolve().parents[1]


def value(expr):
    if expr == '.':
        return '"$item"'
    if re.fullmatch(r'\.[A-Za-z][A-Za-z0-9]*', expr):
        return '"${' + expr[1:] + ':-}"'
    raise ValueError('Unsupported template value: ' + expr)


def condition(expr):
    if expr.startswith('not '):
        return '! ' + condition(expr[4:])
    parts = shlex.split(expr)
    if parts[0] in ('eq', 'ne'):
        return '[[ ' + value(parts[1]) + (' == ' if parts[0] == 'eq' else ' != ') + shlex.quote(parts[2]) + ' ]]'
    field = expr[1:]
    if field in ('KeepParts', 'KeepFstab'):
        return '(( ${#' + field + '[@]} > 0 ))'
    return '[[ -n ${' + field + ':-} && ${' + field + ':-} != 0 ]]'


def compile_template(source):
    # Match the existing text/template whitespace semantics at build time.
    source = re.sub(r'\s*{{-\s', '{{', source)
    source = re.sub(r'\s-}}\s*', '}}', source)
    lines, stack = [], []
    for i, token in enumerate(re.split(r'({{.*?}})', source, flags=re.S)):
        if not token:
            continue
        if not token.startswith('{{'):
            lines.append("printf '%s' " + shlex.quote(token))
            continue
        action = token[2:-2].strip()
        if action.startswith('if '):
            lines.append('if ' + condition(action[3:]) + '; then')
            stack.append('if')
        elif action.startswith('else if '):
            lines.append('elif ' + condition(action[8:]) + '; then')
        elif action == 'else':
            lines.append('else')
        elif action.startswith('range '):
            field = action[7:]
            if field == 'KeepFstab':
                lines.append('for row in "${KeepFstab[@]}"; do')
                lines.append("IFS='|' read -r PartUUID MountPoint FSType Pass <<< \"$row\"")
            else:
                lines.append('for item in "${' + field + '[@]}"; do')
            stack.append('for')
        elif action == 'end':
            lines.append('fi' if stack.pop() == 'if' else 'done')
        else:
            lines.append("printf '%s' " + value(action))
    if stack:
        raise ValueError('Unclosed template block')
    return '\n'.join(lines)


def build():
    parts = [p.read_text(encoding='utf-8').rstrip() for p in sorted((ROOT / 'src/bash').glob('*.sh'))]
    for path in sorted((ROOT / 'src/assets').rglob('*')):
        if not path.is_file():
            continue
        name = re.sub('[^a-zA-Z0-9]', '_', str(path.relative_to(ROOT / 'src/assets')))
        text = path.read_text(encoding='utf-8')
        body = compile_template(text) if '{{' in text else "cat <<'REOS_EMBEDDED_ASSET'\n" + text.rstrip('\n') + '\nREOS_EMBEDDED_ASSET'
        parts.append('asset_' + name + '() {\n' + body + '\n}')
    parts.append('if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi')
    return '\n\n'.join(parts) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = ROOT / 'reos.sh'
    result = build()
    checksum = hashlib.sha256(result.encode('utf-8')).hexdigest() + '  reos.sh' + chr(10)
    checksum_path = ROOT / 'sha256sums.txt'
    if args.check:
        if not checksum_path.exists() or checksum_path.read_text() != checksum:
            raise SystemExit('sha256sums.txt is stale; run python3 tools/build-script.py')
        if not output.exists() or output.read_text(encoding='utf-8') != result:
            raise SystemExit('reos.sh is stale; run python3 tools/build-script.py')
    else:
        output.write_text(result, encoding='utf-8', newline='\n')
        checksum_path.write_text(checksum, encoding='utf-8', newline=chr(10))
