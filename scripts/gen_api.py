"""Write docs/api.html from each package's interface file and the `///` comments in its sources,
so that the reference follows the code.

Usage: python scripts/gen_api.py — from the repository root. CI reruns it and requires no diff.

Every `pub` item the interface file lists has to appear on the page; the script fails when one
does not, so a new function cannot quietly go undocumented.
"""

import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGES = [
    (
        "moonfetch",
        "src",
        "The client, the request it sends, the response it reads, and the values both are made of.",
    ),
    (
        "ws",
        "src/ws",
        "A WebSocket client over ws and wss, on the same connections and TLS settings as HTTP.",
    ),
]
TRAIT_METHODS = re.compile(
    r"::(equal|not_equal|output|to_string|to_repr|hash|hash_combine|compare)\("
)


def sources(folder):
    for path in sorted((ROOT / folder).glob("*.mbt")):
        if path.name.endswith("_test.mbt"):
            continue
        yield path.read_text(encoding="utf-8").splitlines()


DECL = re.compile(
    r"^pub(?:\((?:all|open)\))?\s+(fn|let|struct|enum|suberror|trait|type)\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)"
)


def docs_of(folder):
    """Doc comments by declared name, and inline `//` notes by `Enum.Variant`."""
    out = {}
    for lines in sources(folder):
        pending, owner = [], None
        for line in lines:
            stripped = line.strip()
            if stripped == "///|":
                pending = []
                continue
            if stripped.startswith("///"):
                pending.append(stripped[3:].strip())
                continue
            if stripped.startswith("#"):
                # `#derive` and friends sit between a doc comment and its declaration.
                continue
            m = DECL.match(line)
            if m:
                if pending:
                    out[m.group(2)] = "\n".join(pending)
                owner = m.group(2) if m.group(1) == "enum" and line.rstrip().endswith("{") else None
                pending = []
                continue
            if owner:
                if line.startswith("}"):
                    owner = None
                else:
                    v = re.match(r"\s+([A-Z]\w*)\s*(?://\s*(.*))?$", line)
                    if v and v.group(2):
                        out[owner + "." + v.group(1)] = v.group(2)
            pending = []
    return out


def items_of(folder):
    """Declarations from the interface file, in the order it lists them."""
    lines = (ROOT / folder / "pkg.generated.mbti").read_text(encoding="utf-8").splitlines()
    items, block = [], None
    for line in lines:
        if block is not None:
            if line.startswith("}"):
                items.append(block)
                block = None
            else:
                block["variants"].append(line.strip())
            continue
        m = re.match(r"pub(?:\((?:all|open)\))?\s+(enum|struct|suberror)\s+(\w+)", line)
        if m:
            block = {"kind": m.group(1), "name": m.group(2), "sig": line.rstrip(" {"), "variants": []}
            if not line.rstrip().endswith("{"):
                items.append(block)
                block = None
            continue
        # A handle with private state is a `type` with no constructor.
        m = re.match(r"^type (\w+)$", line)
        if m:
            items.append({"kind": "type", "name": m.group(1), "sig": line, "variants": []})
            continue
        m = re.match(r"pub fn (\w+)::(\w+)", line)
        if m:
            items.append({"kind": "method", "name": m.group(1) + "::" + m.group(2), "sig": line, "owner": m.group(1)})
            continue
        m = re.match(r"pub fn (\w+)", line)
        if m:
            items.append({"kind": "fn", "name": m.group(1), "sig": line})
            continue
        m = re.match(r"pub let (\w+)", line)
        if m:
            items.append({"kind": "let", "name": m.group(1), "sig": line})
            continue
        m = re.match(r"pub impl (\w+) for (\w+)", line)
        if m:
            items.append({"kind": "impl", "name": m.group(1), "sig": line, "owner": m.group(2)})
    return items


FENCE = re.compile(r"```[^\n`]*\n(.*?)```", re.S)


def inline(text):
    if not text:
        return ""
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text, quote=False))
    return f"<p>{text}</p>"


def prose(text):
    """A doc comment: its prose as paragraphs, and the example it carries as a code block."""
    if not text:
        return ""
    out, pos = [], 0
    for m in FENCE.finditer(text):
        out.append(inline(text[pos : m.start()].strip()))
        code = html.escape(m.group(1).strip("\n"), quote=False)
        out.append(f'<pre class="code scroll"><code>{code}</code></pre>')
        pos = m.end()
    out.append(inline(text[pos:].strip()))
    return "".join(part for part in out if part)


def sig(text):
    return f'<pre class="sig">{html.escape(text.strip(), quote=False)}</pre>'


def anchor(pkg, name):
    return f"{pkg}-{name}".replace("::", "-").replace("_", "-").lower()


def render():
    nav, body, rendered = [], [], set()
    for pkg, folder, intro in PACKAGES:
        docs, items = docs_of(folder), items_of(folder)
        route = "moonbitstack/moonfetch" if pkg == "moonfetch" else f"moonbitstack/moonfetch/{pkg}"
        values = [i for i in items if i["kind"] in ("fn", "let")]
        types = [i for i in items if i["kind"] in ("enum", "struct", "suberror", "type", "trait")]
        methods, impls = {}, {}
        for i in items:
            if i["kind"] == "method" and not TRAIT_METHODS.search(i["sig"]):
                methods.setdefault(i["owner"], []).append(i)
            if i["kind"] == "impl":
                impls.setdefault(i["owner"], []).append(i["name"])

        nav.append(f'<li><a href="#{anchor(pkg, "top")}">{pkg}</a><ol class="sub">')
        nav += [f'<li><a href="#{anchor(pkg, i["name"])}">{i["name"]}</a></li>' for i in values + types]
        nav.append("</ol></li>")

        body.append(f'<section class="band" id="{anchor(pkg, "top")}">')
        body.append(f'<div class="band-head"><h2>{pkg}</h2><span class="route">{route}</span></div>')
        body.append(prose(intro))

        for f in values:
            rendered.add((folder, f["name"]))
            body.append(f'<div class="entry" id="{anchor(pkg, f["name"])}">')
            body.append(f'<h3><span class="kind">{f["kind"]}</span>{f["name"]}</h3>')
            body.append(
                prose(docs.get(f["name"], "")) + sig(f["sig"].replace("pub async fn ", "fn ").replace("pub fn ", "fn ").replace("pub let ", "let "))
            )
            body.append("</div>")

        for t in types:
            rendered.add((folder, t["name"]))
            body.append(f'<div class="entry" id="{anchor(pkg, t["name"])}">')
            body.append(f'<h3><span class="kind">{t["kind"]}</span>{t["name"]}</h3>')
            body.append(prose(docs.get(t["name"], "")))
            body.append(sig(t["sig"].replace("pub(all) ", "").replace("pub ", "") + (" {" if t["variants"] else "")))
            if t["variants"]:
                chips = []
                for v in t["variants"]:
                    label = v.split("(")[0].split(" ")[0]
                    note = docs.get(f'{t["name"]}.{label}', "")
                    chips.append(
                        f'<li>{html.escape(v)}'
                        + (f"<small>{html.escape(note)}</small>" if note else "")
                        + "</li>"
                    )
                body.append(f'<ul class="variants">{"".join(chips)}</ul>')
            if impls.get(t["name"]):
                body.append(prose("Implements " + ", ".join(f"`{n}`" for n in impls[t["name"]]) + "."))
            for m in methods.get(t["name"], []):
                rendered.add((folder, m["name"]))
                body.append(
                    f'<div class="member" id="{anchor(pkg, m["name"])}">'
                    + sig(m["sig"].replace("pub fn ", "fn "))
                    + prose(docs.get(m["name"], ""))
                    + "</div>"
                )
            body.append("</div>")
        body.append("</section>")

    missing = []
    for pkg, folder, _ in PACKAGES:
        for item in items_of(folder):
            if item["kind"] == "impl" or TRAIT_METHODS.search(item["sig"]):
                # A trait's own methods are named once, under `Implements` on the type.
                continue
            if (folder, item["name"]) not in rendered:
                missing.append(f'{folder}: {item["kind"]} {item["name"]}')
    if missing:
        print("the reference is missing items the interface file lists:", file=sys.stderr)
        for line in missing:
            print("  " + line, file=sys.stderr)
        return 1

    page = (ROOT / "docs" / "api.template.html").read_text(encoding="utf-8")
    page = page.replace("<!-- nav -->", "\n".join(nav)).replace("<!-- body -->", "\n".join(body))
    (ROOT / "docs" / "api.html").write_text(page, encoding="utf-8", newline="\n")
    total = len(rendered)
    print(f"wrote docs/api.html — {total} items over {len(PACKAGES)} packages")
    return 0


if __name__ == "__main__":
    sys.exit(render())
