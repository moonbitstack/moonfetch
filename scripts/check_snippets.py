"""Compile every MoonBit block in README.md, docs/skills/*/SKILL.md and the site's pages against this
module's source.

A reader pastes these blocks into a project, so each one has to compile as written. The blocks of
one file are read in order, the way the page reads: a block may use a name that an earlier block of
the same file defined. `<!-- nocheck -->` on the line above a block skips it; a block opened with
```` ```mbt native ```` is checked on the native target only. On a page of the site a block is
`<pre data-lang="mbt">` (or `"moonbit"`); `data-native` or `data-target="native"` marks a native one
and `data-nocheck` skips it. A page that declares an alias (`"moonbitstack/moonlog" @serlog`) is read
with that alias.

Usage: python scripts/check_snippets.py [--moon moon] [file ...]
"""

import argparse
import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# In a workspace the dependencies are fetched once, next to moon.work, not beside each module.
CAKES = next((p / ".mooncakes" for p in (ROOT, *ROOT.parents) if (p / ".mooncakes").is_dir()), ROOT / ".mooncakes")
FENCE = re.compile(r"(<!--\s*nocheck\s*-->[ \t]*\n)?```(mbt|moonbit)([^\n]*)\n(.*?)^```", re.S | re.M)
PAGE = re.compile(r'<pre\b([^>]*\bdata-lang="(?:mbt|moonbit)"[^>]*)>(.*?)</pre>', re.S)
# `fn[T] name` and `async fn[T] name` are declarations as much as the unbounded spellings are.
TOP = re.compile(r"^(pub(\([a-z]+\))? |priv |(?:async )?fn(?:\[[^\]\n]*\])? |test |async test |struct |enum |suberror |impl |trait |typealias |type |extern |#[a-z])", re.M)
CONFIG = re.compile(r"(?:\s*//[^\n]*\n)*\s*(import \{|options\(|name\s*=|pkgtype\()")
CORE = {"array", "bench", "bigint", "buffer", "builtin", "bytes", "char", "cmp", "coverage", "deque", "double", "encoding", "env", "error", "float", "hashmap", "hashset", "immut", "int", "int16", "int64", "json", "list", "math", "option", "queue", "quickcheck", "random", "rational", "ref", "result", "set", "sorted_map", "sorted_set", "strconv", "string", "test", "tuple", "uint", "uint16", "uint64", "unit"}
NESTED = {"utf8": "encoding/utf8", "utf16": "encoding/utf16", "base64": "encoding/base64"}
DECLARED = re.compile(r'"([\w\-/]+)"\s+@([a-z_][a-z0-9_]*)')
ALL = ["wasm", "wasm-gc", "js", "native"]


def module_info():
    text = (ROOT / "moon.mod").read_text(encoding="utf-8")
    name = re.search(r'name\s*=\s*"([^"]+)"', text).group(1)
    source = re.search(r'source\s*=\s*"([^"]+)"', text)
    deps = re.findall(r'"([\w-]+/[\w-]+)@[\d.]+"', text)
    src = ROOT / (source.group(1) if source else ".")
    return name, src, deps, backends(src)


def backends(src):
    """The backends the root package has code on, each to be checked on its own; empty means all.

    A file named under `targets` in its moon.pkg, or spelt `name.<backend>.mbt`, builds only there;
    any other builds everywhere. A package with no code on wasm-gc, say, would fail every block there
    with names it does not have, so those backends are left out rather than the whole module limited.
    """
    pkg = src / "moon.pkg"
    text = pkg.read_text(encoding="utf-8") if pkg.exists() else ""
    limited = {f: re.findall(r'"([\w-]+)"', ts) for f, ts in re.findall(r'"([^"/]+\.mbt)"\s*:\s*\[([^\]]*)\]', text)}
    found = set()
    for f in src.glob("*.mbt"):
        if f.name.endswith(("_test.mbt", "_wbtest.mbt")):
            continue
        suffix = re.search(r"\.(native|js|wasm|wasm-gc)\.mbt$", f.name)
        found |= set(limited.get(f.name, [suffix.group(1)] if suffix else ALL))
    return [] if not found or found >= set(ALL) else [t for t in ALL if t in found]


def packages(module, src, deps):
    """Alias to package path: this module's packages first, then what its dependencies publish."""
    found = {}
    for pkg in sorted(src.rglob("moon.pkg")):
        rel = pkg.parent.relative_to(src).as_posix()
        if rel.startswith("snippet_check") or "examples" in rel.split("/") or "internal" in rel.split("/"):
            continue
        path = module if rel == "." else f"{module}/{rel}"
        found.setdefault(path.rsplit("/", 1)[-1], path)
    for dep in deps:
        found.setdefault(dep.rsplit("/", 1)[-1], dep)
        root = CAKES / dep
        if root.is_dir():
            mod = (root / "moon.mod").read_text(encoding="utf-8") if (root / "moon.mod").exists() else ""
            m = re.search(r'source\s*=\s*"([^"]+)"', mod)
            base = root / (m.group(1) if m else ".")
            for pkg in sorted(base.rglob("moon.pkg")):
                rel = pkg.parent.relative_to(base).as_posix()
                if rel != "." and "internal" not in rel.split("/"):
                    found.setdefault(rel.rsplit("/", 1)[-1], f"{dep}/{rel}")
    return found


def page_blocks(text):
    for m in PAGE.finditer(text):
        attrs = m.group(1)
        if "data-nocheck" in attrs:
            continue
        body = html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))
        if CONFIG.match(body):
            continue
        native = "data-native" in attrs or 'data-target="native"' in attrs
        yield text[: m.start(2)].count("\n") + 1, native, body


def blocks(path):
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".html":
        yield from page_blocks(text)
        return
    for m in FENCE.finditer(text):
        if m.group(1) or "nocheck" in m.group(3):
            continue
        # The contents of a `moon.pkg` or `moon.mod` shown in a block are configuration, not code.
        if CONFIG.match(m.group(4)):
            continue
        yield text[: m.start(4)].count("\n") + 1, "native" in m.group(3), m.group(4)


def program(items):
    """One package for one file and target: top-level blocks as they are, statement blocks each in a
    function that also holds the statement blocks before it, so a name defined earlier is in scope."""
    out, spans, earlier = [], [], []
    n = 0
    for line, body in items:
        start = sum(s.count("\n") + 1 for s in out) + 1
        if TOP.search(body):
            chunk = body
        else:
            n += 1
            inner = "\n".join(earlier + [body])
            chunk = f"async fn snippet_{n}() -> Unit raise {{\n{inner}\n}}"
            earlier.append(body)
        out.append(chunk.rstrip("\n") + "\n")
        spans.append((start, start + chunk.count("\n"), line))
    return "\n".join(out), spans


def imports_of(code, written, aliases, named):
    """`code` is the program as compiled; `written` is the blocks as the page has them, since the
    program wraps each statement block in an `async fn` of its own."""
    used = set(re.findall(r"@([a-z_][a-z0-9_]*)\.", code))
    found = {}
    for alias in sorted(used):
        if alias in named:
            found[named[alias]] = alias
        elif alias in aliases:
            found.setdefault(aliases[alias], None)
        elif alias in CORE:
            found.setdefault(f"moonbitlang/core/{alias}", None)
        elif alias in NESTED:
            found.setdefault(f"moonbitlang/core/{NESTED[alias]}", None)
    # A derive names no package, yet the code it writes uses core's json.
    if re.search(r"#derive\([^)]*\b(?:FromJson|ToJson)\b", written):
        found.setdefault("moonbitlang/core/json", None)
    # An `async fn` needs the runtime as much as an `async test` does.
    if re.search(r"\basync (?:fn|test)\b", written):
        found.setdefault("moonbitlang/async", None)
    return sorted(found.items())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--moon", default="moon")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    module, src, deps, backends = module_info()
    if module.endswith("CHANGE-ME"):
        print("the template itself: nothing to check until CHANGE-ME is replaced")
        return 0
    subprocess.run([args.moon, "update"], cwd=ROOT, capture_output=True)
    aliases = packages(module, src, deps)
    files = [Path(f) for f in args.files] or [ROOT / "README.md", *sorted((ROOT / "docs" / "skills").glob("*/SKILL.md")), *sorted((ROOT / "docs").glob("*.html"))]
    failed = 0
    for file in files:
        file = file if file.is_absolute() else ROOT / file
        if not file.exists():
            continue
        named = {alias: path for path, alias in DECLARED.findall(file.read_text(encoding="utf-8"))}
        found = list(blocks(file))
        for native in (False, True):
            items = [(line, body) for line, nat, body in found if nat == native]
            if not items:
                continue
            code, spans = program(items)
            imports = imports_of(code, "\n".join(body for _, body in items), aliases, named)
            pkg = src / "snippet_check"
            shutil.rmtree(pkg, ignore_errors=True)
            pkg.mkdir(parents=True)
            head = "import {\n" + "".join(f'  "{path}"{f" @{alias}" if alias else ""},\n' for path, alias in imports) + "}\n" if imports else ""
            if re.search(r"^(async )?fn main", code, re.M):
                head += '\noptions("is-main": true)\n'
            (pkg / "moon.pkg").write_text(head, encoding="utf-8", newline="\n")
            (pkg / "snippets.mbt").write_text(code, encoding="utf-8", newline="\n")
            wanted = ["native"] if native else (backends or ["all"])
            out, code_rc = "", 0
            try:
                for target in wanted:
                    r = subprocess.run([args.moon, "check", "--target", target, str(pkg.relative_to(ROOT))], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
                    out += r.stdout + r.stderr
                    code_rc = code_rc or r.returncode
            finally:
                shutil.rmtree(pkg, ignore_errors=True)
            bad = set()
            for m in re.finditer(r"Error: \[\d+\][^\n]*\n[^\n]*snippets\.mbt:(\d+):\d+[^\n]*\n(?:[^\n]*\n){0,6}?[^\n]*╰[─┬ ]*(?:─ )?([^\n]+)", out):
                at = int(m.group(1))
                block = next((b for s, e, b in spans if s <= at <= e), None)
                bad.add((block, m.group(2).strip()))
            if code_rc and not bad:
                bad.add((None, out.strip().splitlines()[-1] if out.strip() else "moon check failed"))
            label = "+".join(wanted)
            for block, msg in sorted(bad, key=lambda x: (x[0] or 0)):
                print(f"{file.relative_to(ROOT).as_posix()}:{block}: {msg}")
            failed += len(bad)
            if not bad:
                print(f"{file.relative_to(ROOT).as_posix()}: {len(items)} {label} blocks compile")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
