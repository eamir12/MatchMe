#!/usr/bin/env python3
"""Convert every `Text(... overflow: TextOverflow.ellipsis ...)` in
matchme_admin/lib to SafeText (growable content) or ShrinkText (fixed chrome),
per an explicit decision table. Aborts without writing if any ellipsis site
has no decision (or a decision has no match), so nothing is silently skipped.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), '..', 'matchme_admin', 'lib')
IMPORT = "import 'package:matchme_admin/widgets/safe_text.dart';"

# file (relative to ROOT) -> {ellipsis line number: 'shrink' | 'safe'}
DECISIONS = {
    'main.dart': {
        3002: 'shrink',   # pill toggle label
        4014: 'safe',     # settings row label (compact)
        4038: 'safe',     # settings row label (2-line)
        4923: 'safe',     # data table cell metric
        5012: 'safe',     # ListTile title
        5019: 'safe',     # ListTile subtitle
        5199: 'safe',     # ListTile title
        5206: 'safe',     # ListTile subtitle
        5921: 'safe',     # table cell meta
        5932: 'safe',     # table cell masked name
        5970: 'safe',     # table cell fallback value
        6140: 'shrink',   # AppBar title row
        7119: 'shrink',   # map pin label (fixed 60x72 marker)
        7170: 'shrink',   # map pin label (fixed 60x72 marker)
        7276: 'safe',     # map popup last-active row
        7572: 'shrink',   # chart x-axis labels (fixed slot)
        8673: 'safe',     # ListTile title
        8731: 'safe',     # ListTile title
        11711: 'shrink',  # language dropdown button label
        14160: 'safe',    # notification message body
        17416: 'safe',    # ListTile title
        19140: 'safe',    # verification reviewed-by line
        21506: 'safe',    # review row user name
        21588: 'safe',    # review reason body
    },
    'widgets/admin_offline_indicator.dart': {64: 'safe'},
    'widgets/system_health_cards.dart': {571: 'safe', 584: 'safe',
                                         678: 'safe', 769: 'safe'},
    'screens/user_match_management_dashboard.dart': {841: 'safe',
                                                     1057: 'safe'},
    'screens/promo_code_dashboard.dart': {828: 'shrink', 2178: 'shrink'},
    'screens/external_ads_dashboard.dart': {846: 'shrink'},
    'screens/event_import_feedback_dashboard.dart': {265: 'shrink'},
    'screens/sponsored_ads_dashboard.dart': {3257: 'safe', 3822: 'shrink'},
    'screens/system_health_history_screen.dart': {559: 'safe', 584: 'safe',
                                                  607: 'safe'},
    'screens/match_comparison_dashboard.dart': {1323: 'safe', 1339: 'safe',
                                                1689: 'safe', 2527: 'safe',
                                                2536: 'safe', 3262: 'shrink'},
}


def find_matching_paren(s, open_idx):
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
            nl = s.find('\n', i)
            i = nl if nl != -1 else len(s)
            continue
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_params(inner):
    """Split a Text argument list into (param_text, start, end) at depth-0
    commas, tracking strings and nested (), [], {}."""
    params = []
    start = 0
    depth = 0
    in_str = None
    i = 0
    while i < len(inner):
        c = inner[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'"):
            in_str = c
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            params.append((inner[start:i], start, i))
            start = i + 1
        i += 1
    params.append((inner[start:], start, len(inner)))
    return params


def line_of(src, pos):
    return src.count('\n', 0, pos) + 1


def process(path, decisions):
    with open(path, encoding='utf-8') as f:
        src = f.read()

    # Collect every Text( block that contains an ellipsis, with the line
    # number of the ellipsis itself.
    blocks = []
    for m in re.finditer(r'(?<![A-Za-z0-9_])Text\(', src):
        open_idx = m.end() - 1
        close_idx = find_matching_paren(src, open_idx)
        if close_idx == -1:
            continue
        block = src[m.start():close_idx + 1]
        om = re.search(r'TextOverflow\.ellipsis', block)
        if not om:
            continue
        ell_line = line_of(src, m.start() + om.start())
        blocks.append((m.start(), close_idx + 1, ell_line))

    found = {}
    for _, _, ell_line in blocks:
        found[ell_line] = found.get(ell_line, 0) + 1

    problems = []
    for ell_line, count in sorted(found.items()):
        if ell_line not in decisions:
            problems.append(f'  line {ell_line}: no decision '
                            f'({count} occurrence(s))')
    for ell_line in decisions:
        if ell_line not in found:
            problems.append(f'  decision line {ell_line}: no ellipsis found')
    if problems:
        print(f'ABORT {path}: decision table mismatch:')
        print('\n'.join(problems))
        return None

    # Apply bottom-up so earlier positions stay valid.
    changed = False
    for start, close_idx, ell_line in sorted(blocks, reverse=True):
        mode = decisions[ell_line]
        block = src[start:close_idx]
        inner_open = block.index('(')
        inner = block[inner_open + 1:-1]
        base = start + inner_open + 1

        kept = []
        removals = []
        params = split_params(inner)
        for idx, (text, pstart, pend) in enumerate(params):
            stripped = text.strip()
            is_ellipsis = bool(
                re.fullmatch(r'overflow:\s*TextOverflow\.ellipsis', stripped))
            is_maxlines = bool(re.match(r'maxLines:', stripped))
            is_softwrap = bool(re.match(r'softWrap:', stripped))
            drop = is_ellipsis or (
                mode == 'safe' and (is_maxlines or is_softwrap)) or (
                mode == 'shrink' and is_softwrap)
            if drop:
                removals.append((base + pstart, base + pend, idx))
            else:
                kept.append((base + pstart, base + pend))

        # Compute the spans to delete (whole lines where the param owns its
        # line, inline otherwise, handling separator commas).
        deletes = []
        param_count = len(params)
        for pstart, pend, idx in removals:
            line_start = src.rfind('\n', 0, pstart) + 1
            line_end = src.find('\n', pend)
            if line_end == -1:
                line_end = len(src)
            prefix = src[line_start:pstart]
            suffix = src[pend:line_end]
            if prefix.isspace() and re.fullmatch(r'\s*,?', suffix):
                # Own line: remove it including the newline.
                end = line_end + 1 if line_end < len(src) else line_end
                deletes.append((line_start, end))
                continue
            # Inline: remove the param plus its separator comma.
            after = pend
            while after < len(src) and src[after] in ' \t':
                after += 1
            if after < len(src) and src[after] == ',':
                after += 1
                while after < len(src) and src[after] in ' \t':
                    after += 1
                deletes.append((pstart, after))
                continue
            before = pstart
            while before > 0 and src[before - 1] in ' \t':
                before -= 1
            if before > 0 and src[before - 1] == ',':
                before -= 1
                deletes.append((before, pend))
            else:
                deletes.append((pstart, pend))

        # Merge overlapping/adjacent ranges (two params removed from the
        # same line both claim the shared separator comma).
        merged = []
        for dstart, dend in sorted(deletes):
            if merged and dstart <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], dend))
            else:
                merged.append((dstart, dend))
        for dstart, dend in reversed(merged):
            src = src[:dstart] + src[dend:]

        # Rename the constructor (position unaffected: start is before deletes
        # only if a delete precedes it — deletions are inside the block, so
        # `start` itself never moves).
        src = src[:start] + mode_and_name(mode) + src[start + len('Text('):]
        changed = True

    if changed and IMPORT not in src:
        imports = list(re.finditer(r'^import .*?;$', src, re.M))
        if imports:
            last = imports[-1]
            src = src[:last.end()] + '\n' + IMPORT + src[last.end():]
        else:
            src = IMPORT + '\n' + src

    if changed:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(src)
    return changed


def mode_and_name(mode):
    return 'ShrinkText(' if mode == 'shrink' else 'SafeText('


def main():
    results = []
    for rel, decisions in DECISIONS.items():
        path = os.path.join(ROOT, rel)
        r = process(path, decisions)
        if r is None:
            sys.exit(1)
        results.append((rel, r))
    # Anything with ellipsis that has no entry at all is a bug in the table.
    for dirpath, _, filenames in os.walk(ROOT):
        for fn in filenames:
            if not fn.endswith('.dart'):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT).replace('\\', '/')
            if rel in DECISIONS or rel.endswith('safe_text.dart'):
                continue
            with open(p, encoding='utf-8') as f:
                has_ellipsis = 'TextOverflow.ellipsis' in f.read()
            if has_ellipsis:
                print(f'ABORT: {rel} has ellipsis but no decision entry')
                sys.exit(1)
    for rel, changed in results:
        print(f'{"OK " if changed else "-- "} {rel}')
    print('done')


if __name__ == '__main__':
    main()
