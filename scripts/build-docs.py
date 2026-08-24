#!/usr/bin/env python3
"""Render every Markdown file in docs/ to a self-contained static site in docs/html.

Mermaid fences are preserved as <pre class="mermaid"> blocks and rendered client-side
by a vendored copy of mermaid.js (docs/html/assets/mermaid.min.js), so the output
works offline with no network access.

Usage:
    python3 scripts/build-docs.py            # build
    python3 scripts/build-docs.py --fetch    # (re)download the vendored mermaid.js
"""

from __future__ import annotations

import html as html_mod
import re
import sys
import tempfile
import urllib.request
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = DOCS / "html"
ASSETS = OUT / "assets"

MERMAID_URL = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"
MERMAID_LOCAL = ASSETS / "mermaid.min.js"

# Order of the nav sidebar; anything else is appended alphabetically.
NAV_ORDER = ["README.md", "VBX_DESIGN.md", "FEATURE_PARITY.md"]

MERMAID_FENCE = re.compile(
    r"^[ \t]*```mermaid[ \t]*\n(.*?)^[ \t]*```[ \t]*$",
    re.DOTALL | re.MULTILINE,
)


def fetch_mermaid() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    print(f"fetching {MERMAID_URL}")
    with urllib.request.urlopen(MERMAID_URL, timeout=120) as resp:
        data = resp.read()
    MERMAID_LOCAL.write_bytes(data)
    print(f"wrote {MERMAID_LOCAL} ({len(data) / 1024:.0f} KB)")


def extract_mermaid(text: str) -> tuple[str, list[str]]:
    """Replace mermaid fences with placeholders so Markdown leaves them alone."""
    blocks: list[str] = []

    def sub(match: re.Match[str]) -> str:
        blocks.append(match.group(1))
        return f"\n\nVBXMERMAIDPLACEHOLDER{len(blocks) - 1}ENDPLACEHOLDER\n\n"

    return MERMAID_FENCE.sub(sub, text), blocks


def restore_mermaid(rendered: str, blocks: list[str]) -> str:
    for i, block in enumerate(blocks):
        needle = re.compile(
            r"<p>\s*VBXMERMAIDPLACEHOLDER" + str(i) + r"ENDPLACEHOLDER\s*</p>"
        )
        figure = (
            '<div class="mermaid-wrap">'
            f'<pre class="mermaid">{html_mod.escape(block.strip())}</pre>'
            "</div>"
        )
        rendered, n = needle.subn(lambda _m: figure, rendered, count=1)
        if n == 0:  # placeholder survived outside a <p> (e.g. inside a list)
            rendered = rendered.replace(
                f"VBXMERMAIDPLACEHOLDER{i}ENDPLACEHOLDER", figure, 1
            )
    return rendered


def rewrite_links(rendered: str) -> str:
    """Point .md links at their generated .html siblings.

    Links written relative to docs/ that already reach into html/ (e.g. the
    README pointing at html/index.html) are flattened, because the rendered
    pages themselves live in html/.
    """
    rendered = re.sub(
        r'(href="(?!https?:)[^"#]*?)\.md(?=[#"])',
        lambda m: m.group(1) + ".html",
        rendered,
    )
    return re.sub(r'href="(?:\./)?html/', 'href="', rendered)


def title_of(md_text: str, fallback: str) -> str:
    for line in md_text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{css}</style>
</head>
<body>
<a class="skip" href="#content">Skip to content</a>
<div class="shell">
  <aside class="nav">
    <div class="brand"><span class="dot"></span> vbx docs</div>
    <nav>{nav}</nav>
    <div class="toc-head">On this page</div>
    <nav class="toc">{toc}</nav>
    <button class="theme" type="button" data-theme-toggle>Toggle theme</button>
  </aside>
  <main id="content" class="page">
    <article class="prose">
{body}
    </article>
    <footer class="foot">Generated from <code>docs/{source}</code> &middot; vbx design documentation</footer>
  </main>
</div>
<script src="assets/mermaid.min.js"></script>
<script>
(function () {{
  var root = document.documentElement;
  var stored = null;
  try {{ stored = localStorage.getItem('vbx-theme'); }} catch (e) {{}}
  if (stored) root.setAttribute('data-theme', stored);

  function isDark() {{
    var t = root.getAttribute('data-theme');
    if (t) return t === 'dark';
    return window.matchMedia('(prefers-color-scheme: dark)').matches;
  }}

  function initMermaid() {{
    if (!window.mermaid) return;
    window.mermaid.initialize({{
      startOnLoad: false,
      securityLevel: 'strict',
      theme: isDark() ? 'dark' : 'default',
      fontFamily: 'ui-sans-serif, -apple-system, Segoe UI, Roboto, sans-serif',
      flowchart: {{ curve: 'basis', htmlLabels: true }},
      themeVariables: {{ fontSize: '14px' }}
    }});
    var nodes = document.querySelectorAll('pre.mermaid');
    nodes.forEach(function (n) {{
      if (!n.dataset.src) n.dataset.src = n.textContent;
      n.textContent = n.dataset.src;
      n.removeAttribute('data-processed');
    }});
    window.mermaid.run({{ nodes: nodes }});
  }}

  document.addEventListener('DOMContentLoaded', initMermaid);

  var btn = document.querySelector('[data-theme-toggle]');
  if (btn) btn.addEventListener('click', function () {{
    var next = isDark() ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try {{ localStorage.setItem('vbx-theme', next); }} catch (e) {{}}
    initMermaid();
  }});

  // Highlight the current section in the sidebar TOC while scrolling.
  var links = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
  if (links.length && 'IntersectionObserver' in window) {{
    var map = {{}};
    links.forEach(function (a) {{
      var el = document.getElementById(decodeURIComponent(a.hash.slice(1)));
      if (el) map[el.id] = a;
    }});
    var obs = new IntersectionObserver(function (entries) {{
      entries.forEach(function (en) {{
        var a = map[en.target.id];
        if (!a) return;
        if (en.isIntersecting) {{
          links.forEach(function (l) {{ l.classList.remove('active'); }});
          a.classList.add('active');
        }}
      }});
    }}, {{ rootMargin: '0px 0px -75% 0px', threshold: 0 }});
    Object.keys(map).forEach(function (id) {{
      var el = document.getElementById(id);
      if (el) obs.observe(el);
    }});
  }}
}})();
</script>
</body>
</html>
"""

CSS = """
:root {
  --bg: #ffffff;
  --bg-soft: #f7f8fa;
  --bg-code: #f4f5f7;
  --fg: #1a1c21;
  --fg-soft: #5b6472;
  --fg-faint: #8b94a3;
  --line: #e3e6ec;
  --accent: #4f46e5;
  --accent-soft: #eef2ff;
  --quote: #6d28d9;
  --table-head: #f4f5f9;
  --shadow: 0 1px 2px rgba(16,24,40,.05), 0 8px 24px -12px rgba(16,24,40,.12);
  --mermaid-bg: #ffffff;
}
:root[data-theme="dark"] {
  --bg: #14161a;
  --bg-soft: #191c22;
  --bg-code: #1d2128;
  --fg: #e6e9ef;
  --fg-soft: #a5adbb;
  --fg-faint: #7b8493;
  --line: #2a2f38;
  --accent: #a5b4fc;
  --accent-soft: #23273a;
  --quote: #c4b5fd;
  --table-head: #1d2128;
  --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px -12px rgba(0,0,0,.6);
  --mermaid-bg: #191c22;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #14161a;
    --bg-soft: #191c22;
    --bg-code: #1d2128;
    --fg: #e6e9ef;
    --fg-soft: #a5adbb;
    --fg-faint: #7b8493;
    --line: #2a2f38;
    --accent: #a5b4fc;
    --accent-soft: #23273a;
    --quote: #c4b5fd;
    --table-head: #1d2128;
    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px -12px rgba(0,0,0,.6);
    --mermaid-bg: #191c22;
  }
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 1.5rem; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 16px/1.68 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased;
}
.skip { position: absolute; left: -9999px; }
.skip:focus { left: 1rem; top: 1rem; background: var(--accent); color: #fff; padding: .5rem .75rem; border-radius: 6px; z-index: 50; }

.shell { display: grid; grid-template-columns: 268px minmax(0, 1fr); min-height: 100vh; }

.nav {
  position: sticky; top: 0; align-self: start;
  height: 100vh; overflow-y: auto;
  padding: 1.5rem 1.1rem 2rem;
  background: var(--bg-soft);
  border-right: 1px solid var(--line);
}
.brand { display: flex; align-items: center; gap: .5rem; font-weight: 650; letter-spacing: -.01em; margin-bottom: 1.25rem; }
.brand .dot { width: 10px; height: 10px; border-radius: 3px; background: var(--accent); display: inline-block; }
.nav nav a {
  display: block; padding: .34rem .55rem; margin: .1rem 0;
  border-radius: 6px; color: var(--fg-soft); text-decoration: none; font-size: .9rem;
}
.nav nav a:hover { background: var(--accent-soft); color: var(--fg); }
.nav nav a.current { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
.toc-head {
  margin: 1.5rem 0 .4rem; padding: 0 .55rem;
  font-size: .68rem; text-transform: uppercase; letter-spacing: .09em;
  color: var(--fg-faint); font-weight: 700;
}
.toc { font-size: .84rem; border-left: 1px solid var(--line); margin-left: .55rem; }
.toc ul { list-style: none; margin: 0; padding: 0 0 0 .55rem; }
.toc li ul { padding-left: .7rem; }
.toc a { display: block; padding: .2rem .5rem; color: var(--fg-faint); text-decoration: none; border-radius: 5px; line-height: 1.35; }
.toc a:hover { color: var(--fg); background: var(--accent-soft); }
.toc a.active { color: var(--accent); font-weight: 600; }
.theme {
  margin-top: 1.75rem; width: 100%; padding: .45rem .6rem;
  background: transparent; color: var(--fg-soft);
  border: 1px solid var(--line); border-radius: 7px;
  font: inherit; font-size: .82rem; cursor: pointer;
}
.theme:hover { color: var(--fg); border-color: var(--accent); }

.page { padding: 3rem 3.5rem 5rem; min-width: 0; }
.prose { max-width: 62rem; }

h1, h2, h3, h4 { line-height: 1.25; letter-spacing: -.018em; font-weight: 680; }
h1 { font-size: 2.3rem; margin: 0 0 1.4rem; }
h2 { font-size: 1.5rem; margin: 2.9rem 0 1rem; padding-bottom: .4rem; border-bottom: 1px solid var(--line); }
h3 { font-size: 1.16rem; margin: 2rem 0 .7rem; }
h4 { font-size: 1rem; margin: 1.5rem 0 .5rem; color: var(--fg-soft); }
h1 .toclink, h2 .toclink, h3 .toclink, h4 .toclink { color: inherit; text-decoration: none; }
h1 .toclink:hover, h2 .toclink:hover, h3 .toclink:hover, h4 .toclink:hover { color: var(--accent); }
p { margin: 0 0 1rem; }
a { color: var(--accent); text-decoration-color: color-mix(in srgb, var(--accent) 35%, transparent); text-underline-offset: 2px; }
strong { font-weight: 660; }
hr { border: 0; border-top: 1px solid var(--line); margin: 2.6rem 0; }
ul, ol { margin: 0 0 1rem; padding-left: 1.35rem; }
li { margin: .3rem 0; }
li > ul, li > ol { margin-top: .3rem; }

blockquote {
  margin: 1.4rem 0; padding: .9rem 1.1rem;
  border-left: 3px solid var(--quote);
  background: var(--accent-soft);
  border-radius: 0 8px 8px 0;
  color: var(--fg);
}
blockquote p:last-child { margin-bottom: 0; }

code {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  font-size: .875em;
  background: var(--bg-code);
  padding: .13em .38em;
  border-radius: 4px;
  border: 1px solid var(--line);
}
pre {
  background: var(--bg-code);
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 1rem 1.15rem;
  overflow-x: auto;
  margin: 0 0 1.4rem;
  line-height: 1.55;
}
pre code { background: none; border: 0; padding: 0; font-size: .845rem; }

.table-wrap { overflow-x: auto; margin: 0 0 1.5rem; border: 1px solid var(--line); border-radius: 10px; box-shadow: var(--shadow); }
table { border-collapse: collapse; width: 100%; font-size: .9rem; }
th, td { text-align: left; padding: .6rem .85rem; border-bottom: 1px solid var(--line); vertical-align: top; }
thead th { background: var(--table-head); font-weight: 650; white-space: nowrap; }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover { background: var(--bg-soft); }
td code, th code { white-space: nowrap; }

.mermaid-wrap {
  margin: 0 0 1.6rem;
  padding: 1.1rem;
  background: var(--mermaid-bg);
  border: 1px solid var(--line);
  border-radius: 10px;
  overflow-x: auto;
  box-shadow: var(--shadow);
}
pre.mermaid { background: none; border: 0; padding: 0; margin: 0; text-align: center; }
pre.mermaid svg { max-width: 100%; height: auto; }

.foot { margin-top: 4rem; padding-top: 1.2rem; border-top: 1px solid var(--line); color: var(--fg-faint); font-size: .82rem; }

@media (max-width: 940px) {
  .shell { grid-template-columns: 1fr; }
  .nav { position: static; height: auto; border-right: 0; border-bottom: 1px solid var(--line); }
  .toc { display: none; }
  .page { padding: 2rem 1.25rem 4rem; }
  h1 { font-size: 1.8rem; }
}
@media print {
  .nav, .theme, .skip { display: none; }
  .shell { display: block; }
  .page { padding: 0; }
}
"""


def wrap_tables(rendered: str) -> str:
    """Let wide tables scroll inside their own container instead of the page."""
    return rendered.replace("<table>", '<div class="table-wrap"><table>').replace(
        "</table>", "</table></div>"
    )


def build(out: Path = OUT, vendor: bool = True) -> int:
    if not DOCS.is_dir():
        print("docs/ not found", file=sys.stderr)
        return 1

    sources = sorted(p for p in DOCS.glob("*.md"))
    if not sources:
        print("no markdown files in docs/", file=sys.stderr)
        return 1

    ordered: list[Path] = []
    for name in NAV_ORDER:
        p = DOCS / name
        if p in sources:
            ordered.append(p)
    ordered += [p for p in sources if p not in ordered]

    out.mkdir(parents=True, exist_ok=True)
    quiet = out != OUT
    ASSETS.mkdir(parents=True, exist_ok=True)
    if not MERMAID_LOCAL.exists() and vendor:
        try:
            fetch_mermaid()
        except Exception as exc:  # offline: fall back to a CDN-less stub
            print(f"warning: could not vendor mermaid.js ({exc}); diagrams will not render")
            MERMAID_LOCAL.write_text("/* mermaid.js not vendored */\n")

    titles = {p: title_of(p.read_text(encoding="utf-8"), p.stem) for p in ordered}

    md = markdown.Markdown(
        extensions=["extra", "toc", "sane_lists", "admonition"],
        extension_configs={
            "toc": {"permalink": False, "anchorlink": True, "anchorlink_class": "toclink"}
        },
    )

    for src in ordered:
        raw = src.read_text(encoding="utf-8")
        stripped, blocks = extract_mermaid(raw)
        md.reset()
        body = md.convert(stripped)
        body = restore_mermaid(body, blocks)
        body = wrap_tables(body)
        body = rewrite_links(body)

        target = out / (src.stem + ".html")
        nav_items = []
        for other in ordered:
            cls = ' class="current"' if other is src else ""
            nav_items.append(
                f'<a href="{other.stem}.html"{cls}>{html_mod.escape(titles[other])}</a>'
            )

        page = PAGE.format(
            title=html_mod.escape(titles[src]),
            css=CSS,
            nav="".join(nav_items),
            toc=getattr(md, "toc", ""),
            body=body,
            source=html_mod.escape(src.name),
        )
        target.write_text(page, encoding="utf-8")
        if not quiet:
            print(f"docs/{src.name} -> docs/html/{target.name}  ({len(blocks)} diagrams)")

    index = out / "index.html"
    home = out / "README.html"
    if home.exists():
        index.write_text(home.read_text(encoding="utf-8"), encoding="utf-8")
        if not quiet:
            print("docs/html/index.html (copy of README.html)")

    return 0


def check() -> int:
    """Is the committed HTML what the Markdown would produce right now?

    `docs/html/` is generated and committed, and nothing regenerated it when a
    release rewrote `docs/RELEASES.md` — so the one page whose whole purpose is
    listing releases was the page guaranteed to go stale. It was missing two
    releases when this was found.

    Offline, like every other `--check` in CLAUDE.md's verify block: it renders
    to a temporary directory and compares. The mermaid bundle is not fetched or
    compared — it is a vendored dependency, not output, and reaching the network
    would make the check pass at a desk and fail on a plane.
    """
    with tempfile.TemporaryDirectory() as raw:
        scratch = Path(raw)
        # `vendor=False`: the mermaid bundle is a vendored dependency rather
        # than output, it is not compared, and fetching it would make this
        # check pass at a desk and fail on a plane.
        code = build(out=scratch, vendor=False)
        if code != 0:
            return code

        stale: list[str] = []
        for rendered in sorted(scratch.glob("*.html")):
            committed = OUT / rendered.name
            if not committed.exists():
                stale.append(f"{rendered.name} (never generated)")
            elif committed.read_bytes() != rendered.read_bytes():
                stale.append(rendered.name)

        # A page whose source is gone is drift in the other direction: it is
        # still served, and nothing produces it any more.
        expected = {p.name for p in scratch.glob("*.html")}
        for committed in sorted(OUT.glob("*.html")):
            if committed.name not in expected:
                stale.append(f"{committed.name} (no longer has a source)")

    if stale:
        print("error: docs/html is stale — regenerate with scripts/build-docs.py",
              file=sys.stderr)
        for name in stale:
            print(f"  {name}", file=sys.stderr)
        return 1

    print(f"==> docs check ok ({len(list(OUT.glob('*.html')))} pages match their Markdown)")
    return 0


if __name__ == "__main__":
    if "--fetch" in sys.argv:
        fetch_mermaid()
    if "--check" in sys.argv:
        raise SystemExit(check())
    raise SystemExit(build())
