"""Fill the numbers a page shows from the source of truth, so that no version or count is typed
by hand and forgotten.

Usage: python scripts/gen_site.py — from the repository root. CI reruns it and requires no diff.

A number lives in the page as an element marked `data-fill="name"`; this script rewrites what is
inside it. Running it twice changes nothing.
"""

import pathlib
import re
import sys

import gen_api

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGES = sorted((ROOT / "docs").glob("*.html"))


def version():
    text = (ROOT / "moon.mod").read_text(encoding="utf-8")
    return re.search(r'version\s*=\s*"([^"]+)"', text).group(1)


def counted():
    """Public items, counted the way the reference lists them: values, types and their methods."""
    total = 0
    for _, folder, _ in gen_api.PACKAGES:
        items = gen_api.items_of(folder)
        for item in items:
            if item["kind"] == "impl" or gen_api.TRAIT_METHODS.search(item["sig"]):
                continue
            total += 1
    return total


def fill(text, name, value):
    pattern = re.compile(r'(<[a-zA-Z]+[^>]*\bdata-fill="' + name + r'"[^>]*>)(.*?)(</)', re.S)
    return pattern.sub(lambda m: m.group(1) + value + m.group(3), text)


def main():
    numbers = {"version": version(), "items": str(counted())}
    changed = 0
    for path in PAGES:
        text = path.read_text(encoding="utf-8")
        filled = text
        for name, value in numbers.items():
            filled = fill(filled, name, value)
        if filled != text:
            path.write_text(filled, encoding="utf-8", newline="\n")
            changed += 1
    print(f"filled {', '.join(f'{k}={v}' for k, v in numbers.items())} — {changed} page(s) changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
