#!/usr/bin/env python3
"""Rewrite `title: Text(` -> `title: ShrinkText(` inside AppBar(...) argument
lists only (balanced-paren scan), and ensure safe_text.dart is imported."""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), '..', 'lib')
IMPORT = "import 'package:matchme/widgets/safe_text.dart';"


def find_matching_paren(s, open_idx):
    """Given index of '(', return index of matching ')'."""
    depth = 0
    i = open_idx
    in_str = None
    while i < len(s):
        c = s[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'"):
            in_str = c
        elif c == '/' and i + 1 < len(s) and s[i + 1] == '/':
            # line comment
            nl = s.find('\n', i)
            i = (nl if nl != -1 else len(s))
            continue
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def process(path):
    with open(path, encoding='utf-8') as f:
        src = f.read()
    out = []
    pos = 0
    changed = 0
    for m in re.finditer(r'\bAppBar\(', src):
        start = m.start()
        open_idx = m.end() - 1
        close_idx = find_matching_paren(src, open_idx)
        if close_idx == -1:
            continue
        block = src[start:close_idx + 1]
        # Only rewrite `title: Text(` at the AppBar's own argument level:
        # scan within the block for the literal at depth 1.
        new_block = []
        bpos = 0
        i = open_idx - start + 1  # inside block
        depth = 1
        in_str = None
        while i < len(block) - 1:
            c = block[i]
            if in_str:
                if c == '\\':
                    i += 2
                    continue
                if c == in_str:
                    in_str = None
            elif c in ('"', "'"):
                in_str = c
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            elif depth == 1:
                mm = re.match(r'title:\s*Text\(', block[i:])
                if mm:
                    new_block.append(block[bpos:i])
                    new_block.append('title: ShrinkText(')
                    bpos = i + mm.end()  # skip the '(' we just wrote
                    changed += 1
                    i = bpos
                    continue
            i += 1
        new_block.append(block[bpos:])
        new_block_s = ''.join(new_block)
        out.append(src[pos:start])
        out.append(new_block_s)
        pos = close_idx + 1
    out.append(src[pos:])
    new_src = ''.join(out)
    if changed and IMPORT not in new_src:
        # insert after the last top-of-file import
        imports = list(re.finditer(r"^import .*?;$", new_src, re.M))
        if imports:
            last = imports[-1]
            new_src = new_src[:last.end()] + '\n' + IMPORT + new_src[last.end():]
        else:
            new_src = IMPORT + '\n' + new_src
    if new_src != src:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(new_src)
    return changed


def main():
    total = 0
    files = 0
    for dirpath, _, filenames in os.walk(ROOT):
        for fn in filenames:
            if not fn.endswith('.dart'):
                continue
            p = os.path.join(dirpath, fn)
            n = process(p)
            if n:
                total += n
                files += 1
                print(f'{n:3d}  {os.path.relpath(p, ROOT)}')
    print(f'TOTAL: {total} replacements in {files} files')


if __name__ == '__main__':
    main()
