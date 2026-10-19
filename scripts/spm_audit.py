#!/usr/bin/env python3
"""Static Swift Package Manager dependency audit for the Flutter iOS build.

Flutter's SPM integration hands the iOS build a graph made of every plugin
package in pubspec.lock plus their transitive Swift package dependencies.
This script approximates Xcode's resolver *without* a Mac:

  1. Finds every Package.swift that Flutter would expose (ios/, macos/,
     darwin/ folders of the locked packages, plus path overrides).
  2. Walks the remote transitive closure, fetching each package manifest at
     the highest version/revision allowed by all constraints.
  3. Reports version-range conflicts, platform-floor violations, package
     identity collisions, and revision/branch conflicts.

SwiftPM semantics emulated:

  * Package identity is the URL basename (lowercased). Two different URLs
    with the same basename are ONE node in the graph, so their version
    constraints are intersected; two different pins for one identity are
    unresolvable.
  * For non-root packages, a package dependency is only kept if some
    non-test target of the declaring package depends on it (target
    dependency or plugin usage). Test-only dependencies are pruned, exactly
    like Manifest.dependenciesRequired() in SwiftPM. Pass --keep-test-deps
    to audit the pessimistic superset instead.
  * Version-specific manifests (Package@swift-X.Y.swift) are selected by
    the highest swift-tools-version <= --swift-version.

Exit code is 1 when a hard conflict (empty version intersection, two pins
for one identity, or an unfetchable manifest) is found, so this can gate a
CI pipeline before it reaches Codemagic.

Usage:
    python3 scripts/spm_audit.py [--root .] [--keep-test-deps] [--verbose]

Requires: Python 3.9+, git, network access to GitHub.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from collections import OrderedDict, defaultdict

# --------------------------------------------------------------------------
# Versions and constraints
# --------------------------------------------------------------------------


def vtuple(s):
    s = s.strip().lstrip("vV")
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?$", s)
    if not m:
        return None
    return tuple(int(x or 0) for x in m.groups())


def bump_major(v):
    return (v[0] + 1, 0, 0, 0)


class Constraint:
    """Half-open [lo, hi) or closed [lo, hi] version range."""

    def __init__(self, lo, hi, hi_inclusive=False):
        self.lo, self.hi, self.hi_inclusive = lo, hi, hi_inclusive

    def contains(self, v):
        if v < self.lo:
            return False
        if self.hi is None:
            return True
        return v <= self.hi if self.hi_inclusive else v < self.hi

    def __repr__(self):
        def fmt(v):
            parts = list(v)
            while len(parts) > 3 and parts[-1] == 0:
                parts.pop()
            return ".".join(map(str, parts))

        if self.hi_inclusive and self.hi == self.lo:
            return f"exact {fmt(self.lo)}"
        hi = fmt(self.hi) if self.hi else "inf"
        return f"[{fmt(self.lo)}, {hi}{']' if self.hi_inclusive else ')'}"


# --------------------------------------------------------------------------
# Manifest parsing
# --------------------------------------------------------------------------

DEP_RE = re.compile(
    r'\.package\(\s*(?:name:\s*"(?P<name>[^"]*)"\s*,\s*)?url:\s*"(?P<url>[^"]+)"\s*,\s*'
    r'(?:(?P<kind>from|exact|branch|revision):\s*(?P<val>"[^"]+"|[A-Za-z_]\w*)'
    r'|"(?P<lo>[^"]+)"\s*(?P<op>\.\.<|\.\.\.)\s*"(?P<hi>[^"]+)")'
)
UTN_RE = re.compile(
    r'\.package\(\s*(?:name:\s*"(?P<name>[^"]*)"\s*,\s*)?url:\s*"(?P<url>[^"]+)"\s*,\s*'
    r'\.upToNext(?P<kind>Major|Minor)\(from:\s*(?P<val>"[^"]+"|[A-Za-z_]\w*)\)'
)
TARGET_REF_RE = re.compile(r'package:\s*"([^"]+)"')
NON_TEST_CALLS = (".target", ".executableTarget", ".plugin", ".macro", ".systemLibrary")
VSM_SUFFIXES = ("5.7", "5.8", "5.9", "5.10", "6.0", "6.1", "6.2", "6.3", "6.4")


class Dep:
    def __init__(self, url, name, constraint, pin):
        self.url = url
        self.name = name
        self.constraint = constraint
        self.pin = pin


def norm_url(url):
    u = url.strip().rstrip("/")
    while u.lower().endswith(".git"):
        u = u[:-4]
    return u


def ident_of(url):
    return norm_url(url).split("/")[-1].lower()


def parse_manifest(text):
    flat = re.sub(r"\s+", " ", text)
    consts = dict(re.findall(r'let\s+(\w+)\s*(?::\s*Version)?\s*=\s*"([^"]+)"', flat))

    def val(x):
        if x is None:
            return None
        x = x.strip('"')
        return consts.get(x, x)

    deps = []
    for m in DEP_RE.finditer(flat):
        url = val(m.group("url"))
        if not url or not url.startswith("http"):
            continue
        kind = m.group("kind")
        if kind == "from":
            lo = vtuple(val(m.group("val")))
            deps.append(Dep(url, m.group("name"), Constraint(lo, bump_major(lo)) if lo else None, None))
        elif kind == "exact":
            lo = vtuple(val(m.group("val")))
            deps.append(Dep(url, m.group("name"), Constraint(lo, lo, True) if lo else None, None))
        elif kind in ("branch", "revision"):
            deps.append(Dep(url, m.group("name"), None, val(m.group("val"))))
        elif kind is None:
            lo, hi = vtuple(val(m.group("lo"))), vtuple(val(m.group("hi")))
            if lo and hi:
                deps.append(Dep(url, m.group("name"),
                                Constraint(lo, hi, m.group("op") == "..."), None))
    for m in UTN_RE.finditer(flat):
        url = val(m.group("url"))
        lo = vtuple(val(m.group("val")))
        if url and url.startswith("http") and lo:
            hi = bump_major(lo) if m.group("kind") == "Major" else (lo[0], lo[1] + 1, 0, 0)
            deps.append(Dep(url, m.group("name"), Constraint(lo, hi), None))
    return deps


def _balanced_blocks(text, call):
    """Yield parenthesized call blocks for `call` with balanced parens."""
    for m in re.finditer(re.escape(call) + r"\s*\(", text):
        start = m.start()
        depth = 0
        i = m.end() - 1
        in_str = False
        while i < len(text):
            ch = text[i]
            if in_str:
                if ch == "\\":
                    i += 2
                    continue
                if ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    yield text[start:i + 1]
                    break
            i += 1


def _array_after(text, start):
    """Return the contents of the first bracketed array after `start`."""
    i = text.find("[", start)
    if i < 0:
        return None
    depth = 0
    in_str = False
    j = i
    while j < len(text):
        ch = text[j]
        if in_str:
            if ch == "\\":
                j += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
        j += 1
    return None


DEFINITION_MARKERS = ("dependencies:", "path:", "sources:", "resources:",
                      "publicHeadersPath", "swiftSettings:", "cSettings:",
                      "linkerSettings:", "exclude:", "type:", "url:",
                      "pkgConfig:", "checksum:")


def product_target_closure(text):
    """Targets reachable from the package's products, as SwiftPM sees them.

    Test targets and orphan helper targets (e.g. Firebase's
    SharedTestUtilities) are not products and must not contribute package
    dependencies. Returns None if the products could not be parsed.
    """
    seeds = []
    for call in (".library", ".executable", ".plugin"):
        for block in _balanced_blocks(text, call):
            m = re.search(r"\btargets:\s*", block)
            if not m:
                continue
            arr = _array_after(block, m.end())
            if arr is not None:
                seeds.extend(re.findall(r'"([^"]+)"', arr))
    if not seeds:
        return None

    blocks = {}
    for call in NON_TEST_CALLS + (".testTarget", ".binaryTarget"):
        for block in _balanced_blocks(text, call):
            m = re.search(r'\bname:\s*"([^"]+)"', block)
            if not m or not any(k in block for k in DEFINITION_MARKERS):
                continue
            blocks.setdefault(m.group(1), block)

    known = set(blocks)
    deps = {}
    for name, block in blocks.items():
        edges = {n for n in re.findall(r'\.target\(\s*name:\s*"([^"]+)"', block) if n in known}
        m = re.search(r"\bdependencies:\s*", block)
        if m:
            arr = _array_after(block, m.end())
            if arr is not None:
                arr = re.sub(r"\.product\([^)]*\)", "", arr)
                edges.update(s for s in re.findall(r'"([^"]+)"', arr) if s in known)
        deps[name] = edges

    reachable, stack = set(), [s for s in seeds if s in blocks]
    while stack:
        name = stack.pop()
        if name in reachable:
            continue
        reachable.add(name)
        stack.extend(deps.get(name, ()))
    return reachable, blocks


def scan_targets(text):
    """Return (package refs reachable from products, parsed successfully)."""
    result = product_target_closure(text)
    if result is None:
        return set(), False
    reachable, blocks = result
    refs = set()
    for name in reachable:
        block = blocks[name]
        if block.lstrip().startswith(".testTarget"):
            continue
        refs.update(x.lower() for x in TARGET_REF_RE.findall(block))
        m = re.search(r"\bdependencies:\s*", block)
        if m:
            arr = _array_after(block, m.end())
            if arr is not None:
                arr = re.sub(r"\.product\([^)]*\)", "", arr)
                refs.update(s.lower() for s in re.findall(r'"([^"]+)"', arr))
    return refs, True


def prune_test_only_deps(deps, refs, saw_targets):
    """Emulate SwiftPM dependenciesRequired() for non-root packages.

    A package dependency survives only if a non-test target (or plugin)
    references it. Manifests where no target blocks could be parsed at all
    are left untouched so unknown formats fail safe.
    """
    if not saw_targets:
        return deps, []
    kept, dropped = [], []
    for d in deps:
        names = {ident_of(d.url), (d.name or "").lower()}
        (kept if names & refs else dropped).append(d)
    return kept, dropped


def parse_platforms(text):
    out = {}
    m = re.search(r"platforms:\s*\[(.*?)\]", text, re.S)
    if not m:
        return out
    body = m.group(1)
    for osname in ("iOS", "macOS", "macCatalyst", "tvOS", "watchOS"):
        mm = re.search(rf"\.{osname}\(\.v(\d+)(?:_(\d+))?\)", body)
        if mm:
            out[osname] = (int(mm.group(1)), int(mm.group(2) or 0), 0, 0)
            continue
        mm = re.search(rf'\.{osname}\("([\d.]+)"\)', body)
        if mm:
            out[osname] = vtuple(mm.group(1))
    return out


# --------------------------------------------------------------------------
# Project scanning
# --------------------------------------------------------------------------


def find_repo_root(start):
    d = os.path.abspath(start)
    for _ in range(6):
        if os.path.exists(os.path.join(d, "pubspec.lock")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return os.path.abspath(start)


def pub_cache_dir():
    env = os.environ.get("PUB_CACHE")
    if env:
        return env
    if os.name == "nt":
        return os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pub", "Cache")
    return os.path.join(os.path.expanduser("~"), ".pub-cache")


def parse_lock(path):
    text = open(path, encoding="utf-8").read()
    pkgs, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if m:
            cur = m.group(1)
            pkgs[cur] = {"name": cur}
            continue
        if cur is None:
            continue
        for key, pattern in (("source", r"^    source: (\S+)"),
                             ("version", r'^    version: "([^"]+)"'),
                             ("path", r'^      path: "([^"]+)"')):
            m = re.match(pattern, line)
            if m:
                pkgs[cur][key] = m.group(1)
    return pkgs


def pkg_dir(p, cache, root):
    if p.get("source") == "hosted":
        d = os.path.join(cache, f'{p["name"]}-{p.get("version", "")}')
        return d if os.path.isdir(d) else None
    if p.get("source") == "path" and p.get("path"):
        return os.path.join(root, p["path"].replace("/", os.sep))
    return None


def find_manifests(d):
    out = []
    for plat in ("ios", "macos", "darwin"):
        base = os.path.join(d, plat)
        if not os.path.isdir(base):
            continue
        for dirpath, dirs, files in os.walk(base):
            dirs[:] = [x for x in dirs if x not in ("example", "test", "tests", "Tests", ".build")]
            if "Package.swift" in files:
                out.append(os.path.join(dirpath, "Package.swift"))
    return out


# --------------------------------------------------------------------------
# Remote fetching
# --------------------------------------------------------------------------


class Fetcher:
    def __init__(self, work_dir, swift_version):
        self.work_dir = work_dir
        self.swift_version = vtuple(swift_version)
        self._tags = {}
        self._files = {}
        os.makedirs(work_dir, exist_ok=True)

    @staticmethod
    def _parse(url):
        m = re.match(r"https://github\.com/([^/]+)/([^/]+)$", norm_url(url))
        return (m.group(1), m.group(2)) if m else None

    def _get(self, owner, repo, ref, name):
        key = f"{owner}__{repo}__{ref}__{name}".replace("/", "_")
        path = os.path.join(self.work_dir, key)
        if os.path.exists(path):
            return open(path, encoding="utf-8", errors="ignore").read()
        raw = f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{name}"
        try:
            req = urllib.request.Request(raw, headers={"User-Agent": "spm-audit"})
            with urllib.request.urlopen(req, timeout=45) as r:
                data = r.read().decode("utf-8", "ignore")
        except Exception:
            return None
        open(path, "w", encoding="utf-8").write(data)
        return data

    def manifest(self, url, ref):
        url = norm_url(url)
        key = (url, ref)
        if key in self._files:
            return self._files[key]
        parts = self._parse(url)
        if not parts:
            self._files[key] = None
            return None
        owner, repo = parts
        candidates = []
        for name in ("Package.swift",) + tuple(f"Package@swift-{s}.swift" for s in VSM_SUFFIXES):
            txt = self._get(owner, repo, ref, name)
            if txt is None:
                continue
            mt = re.search(r"swift-tools-version:\s*([\d.]+)", txt)
            tv = vtuple(mt.group(1)) if mt else (0, 0, 0, 0)
            candidates.append((tv, txt))
        if not candidates:
            self._files[key] = None
            return None
        upper = (self.swift_version[0], self.swift_version[1], 99, 0)
        usable = [c for c in candidates if c[0] <= upper] or candidates
        self._files[key] = max(usable, key=lambda c: c[0])[1]
        return self._files[key]

    def tags(self, url):
        url = norm_url(url)
        if url in self._tags:
            return self._tags[url]
        try:
            env = dict(os.environ)
            env["GIT_TERMINAL_PROMPT"] = "0"
            out = subprocess.run(
                ["git", "ls-remote", "--tags", "--refs", url],
                capture_output=True, text=True, timeout=90, env=env)
        except Exception:
            self._tags[url] = []
            return []
        res = []
        for line in out.stdout.splitlines():
            if "refs/tags/" not in line:
                continue
            t = line.split("refs/tags/", 1)[1].strip()
            v = vtuple(t)
            if v:
                res.append((v, t))
        res.sort(key=lambda x: x[0], reverse=True)
        self._tags[url] = res
        return res


# --------------------------------------------------------------------------
# Audit
# --------------------------------------------------------------------------


def run_audit(args):
    root = find_repo_root(args.root)
    cache = os.path.join(pub_cache_dir(), "hosted", "pub.dev")
    work = args.cache_dir or os.path.join(tempfile.gettempdir(), "spm_audit_cache")
    work = os.path.abspath(work)
    fetch = Fetcher(work, args.swift_version)

    seed = OrderedDict()   # ident -> {urls, constraints, pins, rev}
    pruned_log = []
    manifests_scanned = 0

    def entry_for(ident):
        return seed.setdefault(ident, {"urls": [], "constraints": [], "pins": {}, "rev": 0})

    def add_dep(src_kind, src, dep):
        url = norm_url(dep.url)
        e = entry_for(ident_of(url))
        if (url, src_kind, src) not in e["urls"]:
            e["urls"].append((url, src_kind, src))
        if dep.pin is not None:
            if src not in e["pins"].setdefault(dep.pin, []):
                e["pins"][dep.pin].append(src)
                e["rev"] += 1
        elif dep.constraint is not None:
            key = (src_kind, src, repr(dep.constraint))
            if not any(k == key for k, _ in e["constraints"]):
                e["constraints"].append((key, dep.constraint))
                e["rev"] += 1

    # ---- seed: direct remote dependencies of every Flutter plugin manifest
    pkgs = parse_lock(os.path.join(root, "pubspec.lock"))
    for name, p in pkgs.items():
        d = pkg_dir(p, cache, root)
        if not d or not os.path.isdir(d):
            continue
        for man in find_manifests(d):
            text = open(man, encoding="utf-8", errors="ignore").read()
            manifests_scanned += 1
            deps = parse_manifest(text)
            if not args.keep_test_deps:
                refs, saw = scan_targets(text)
                deps, dropped = prune_test_only_deps(deps, refs, saw)
                pruned_log.extend(f"{name}: {dd.url}" for dd in dropped)
            src = f"{name}:{os.path.relpath(man, d)}"
            for dep in deps:
                add_dep("local", src, dep)

    # ---- remote closure: re-resolve whenever new constraints arrive
    resolved = {}       # ident -> (version, url)
    state = {}          # ident -> rev at last resolution
    expanded = set()    # (url, version) manifests already expanded
    errors = OrderedDict()
    plat_info = {}

    def try_resolve(ident):
        e = seed[ident]
        if len(e["pins"]) > 1:
            msg = "different pins for one identity: " + "; ".join(
                f"{v} (from {', '.join(srcs)})" for v, srcs in e["pins"].items())
            return None, msg
        if e["pins"]:
            pin = next(iter(e["pins"]))
            url = next((u for u, _, s in e["urls"] if s in e["pins"][pin]), e["urls"][0][0])
            return (pin, url), None
        cons = [c for _, c in e["constraints"]]
        for u in sorted({u for u, _, _ in e["urls"]}):
            cand = [t for v, t in fetch.tags(u) if all(c.contains(v) for c in cons)]
            if cand:
                return (cand[0], u), None
        req = "\n".join(f"      required by {src}: {c}" for (_, src, _), c in e["constraints"])
        return None, f"no version satisfies all constraints ({req})"

    while True:
        progress = False
        for ident in list(seed.keys()):
            e = seed[ident]
            if ident in state and state[ident] == e["rev"]:
                continue
            progress = True
            state[ident] = e["rev"]
            picked, err = try_resolve(ident)
            if err:
                errors[ident] = err
                resolved.pop(ident, None)
                continue
            errors.pop(ident, None)
            version, url = picked
            resolved[ident] = (version, url)
            if (url, version) in expanded:
                continue
            expanded.add((url, version))
            text = fetch.manifest(url, version)
            if text is None:
                errors[ident] = f"could not fetch manifest for {url} @ {version}"
                continue
            deps = parse_manifest(text)
            if not args.keep_test_deps:
                refs, saw = scan_targets(text)
                deps, dropped = prune_test_only_deps(deps, refs, saw)
                pruned_log.extend(f"{url}@{version}: {dd.url}" for dd in dropped)
            plats = parse_platforms(text)
            if plats:
                plat_info[url] = plats
            for dep in deps:
                add_dep("remote", f"{url}@{version}", dep)
        if not progress:
            break

    # ---- report
    out = [
        f"repo root:       {root}",
        f"pub cache:       {cache}",
        f"manifests:       {manifests_scanned} plugin manifest(s) scanned",
        f"remote closure:  {len(resolved)} package identit(ies) resolved",
        "",
        "direct remote dependencies of plugin manifests:",
    ]
    for ident, e in sorted(seed.items()):
        local = [(u, s) for u, k, s in e["urls"] if k == "local"]
        if not local:
            continue
        out.append(f"  {ident}:")
        for url, src in sorted(set(local)):
            req = "?"
            for (k, s, _), c in e["constraints"]:
                if s == src:
                    req = str(c)
            for pin, srcs in e["pins"].items():
                if src in srcs:
                    req = f"pin {pin}"
            out.append(f"    {url}  ({req}, from {src})")

    out.append("")
    out.append("resolved remote versions:")
    for ident in sorted(resolved):
        version, url = resolved[ident]
        out.append(f"  {ident}: {version}")
    unresolved = sorted(set(seed) - set(resolved))
    for ident in unresolved:
        out.append(f"  {ident}: UNRESOLVED")

    if args.verbose:
        out.append("")
        out.append(f"pruned test-only dependencies ({len(pruned_log)}):")
        out.extend(f"  {line}" for line in pruned_log)
    else:
        out.append("")
        out.append(f"test-only dependencies pruned: {len(pruned_log)} (use --verbose to list)")

    collisions = {i: sorted({u for u, _, _ in e["urls"]})
                  for i, e in seed.items() if len({u for u, _, _ in e["urls"]}) > 1}
    out.append("")
    out.append("identity collisions (same basename, different URLs):")
    if collisions:
        for ident, urls in sorted(collisions.items()):
            pins = seed[ident]["pins"]
            kind = "HARD (different pins)" if len(pins) > 1 else "warning (constraints merged)"
            out.append(f"  [{kind}] {ident}:")
            out.extend(f"      {u}" for u in urls)
    else:
        out.append("  none")

    mixed = sorted(i for i, e in seed.items() if e["pins"] and e["constraints"])
    out.append("")
    out.append("pin + version constraints on one identity (pin wins in SwiftPM):")
    out.append("  " + (", ".join(mixed) if mixed else "none"))

    out.append("")
    out.append("platform floors above iOS 16.0 / macOS 12.0:")
    high = []
    for url, plats in sorted(plat_info.items()):
        ios, mac = plats.get("iOS"), plats.get("macOS")
        if ios and ios > (16, 0, 0, 0):
            high.append(f"  !! {url}: iOS {ios[0]}.{ios[1]}")
        if mac and mac > (12, 0, 0, 0):
            high.append(f"  note {url}: macOS {mac[0]}.{mac[1]} (app target is 10.15)")
    out.extend(high or ["  none"])

    out.append("")
    out.append("errors:")
    if errors:
        for ident, msg in errors.items():
            out.append(f"  !! {ident}: {msg}")
    else:
        out.append("  none")

    print("\n".join(out))
    hard_pin_clash = any(len(seed[i]["pins"]) > 1 for i in collisions)
    return 1 if (errors or hard_pin_clash) else 0


def main():
    ap = argparse.ArgumentParser(description="Static SPM dependency audit for Flutter iOS builds")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--root", default=os.path.dirname(here),
                    help="project root containing pubspec.lock (default: parent of scripts/)")
    ap.add_argument("--swift-version", default="6.2",
                    help="Swift version used to pick Package@swift-X.Y.swift manifests (default 6.2)")
    ap.add_argument("--keep-test-deps", action="store_true",
                    help="do not prune dependencies used only by test targets")
    ap.add_argument("--verbose", action="store_true", help="list pruned dependencies")
    ap.add_argument("--cache-dir", default=None, help="manifest download cache directory")
    args = ap.parse_args()
    sys.exit(run_audit(args))


if __name__ == "__main__":
    main()
