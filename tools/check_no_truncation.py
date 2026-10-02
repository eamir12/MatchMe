#!/usr/bin/env python3
"""NO-TRUNCATION policy guard — run in CI.

Fails if any user-visible Text truncates:
  - TextOverflow.ellipsis / .clip / .fade
  - softWrap: false
  - maxLines: 1  (single-line cap; use SafeText wrap or ShrinkText shrink)
  - "$key..." style synthesized ellipsis fallbacks

Allowlist: lib/widgets/safe_text.dart documents the forbidden patterns
in comments, so it is excluded from the scan.

Usage: python3 tools/check_no_truncation.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "lib"
ALLOW = {"lib/widgets/safe_text.dart"}

PATTERNS = {
    "ellipsis/clip/fade": re.compile(r"TextOverflow\.(ellipsis|clip|fade)"),
    "softWrap:false": re.compile(r"softWrap\s*:\s*false"),
    "maxLines:1": re.compile(r"maxLines\s*:\s*1\b"),
    # Only flag code that PRODUCES a "..." fallback (?? / return).
    # Equality checks (== '$key...') are backward-compat detectors for
    # values produced before the policy change — not violations.
    "synthesized ... fallback": re.compile(
        r"(\?\?|return)\s*['\"]\$key\.\.\.['\"]"
    ),
}

failures: list[str] = []
for f in sorted(ROOT.rglob("*.dart")):
    rel = f.relative_to(ROOT.parents[0]).as_posix()
    if rel in ALLOW:
        continue
    try:
        lines = f.read_text(encoding="utf-8").splitlines()
    except Exception as e:  # noqa: BLE001
        print(f"SKIP {rel}: {e}")
        continue
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        # Ignore pure comments — policy targets widget code.
        if stripped.startswith("//"):
            continue
        for name, pat in PATTERNS.items():
            if pat.search(line):
                failures.append(f"{rel}:{i} [{name}] {stripped[:160]}")

if failures:
    print("NO-TRUNCATION POLICY VIOLATIONS:")
    for v in failures:
        print(f"  {v}")
    print(
        "\nFix: use SafeText (wrap) or ShrinkText (auto-shrink) from "
        "lib/widgets/safe_text.dart. See file header for guidance."
    )
    sys.exit(1)
print("OK: no truncation patterns found.")
