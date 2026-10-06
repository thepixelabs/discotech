#!/usr/bin/env python3
"""Static checks for the landing page in site/. Standard library only.

    python3 scripts/check-site.py [site_dir]

Fails (exit 1) on:
  * HTML that doesn't parse cleanly: unbalanced structural tags, duplicate ids,
    missing <html lang> or <title>, in-page #fragment links with no target;
  * a local reference (src, href, srcset, CSS url(), manifest icon) to a missing file;
  * a resource loaded from another host, or a script that makes network requests.
    The site promises "loads nothing from other servers"; this keeps that true;
  * a developer path ("/Users/") anywhere in the site;
  * the YOUR_USERNAME placeholder outside an HTML comment;
  * the Download buttons not pointing at the stable direct-download URL.
"""
from __future__ import annotations

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote

STABLE_DMG_URL = "https://github.com/thepixelabs/discotech/releases/latest/download/Discotech-macOS.dmg"
TEXT_SUFFIXES = {".html", ".css", ".js", ".json", ".xml", ".txt", ".webmanifest", ".svg"}
# Tags we expect to be closed explicitly in this hand-written site.
MUST_CLOSE = {
    "html", "head", "body", "header", "main", "footer", "section", "article", "nav", "aside",
    "div", "ul", "ol", "a", "button", "script", "style", "figure", "figcaption", "picture",
    "h1", "h2", "h3", "h4", "h5", "h6", "span", "code", "pre", "table", "form", "label",
    "select", "textarea", "title", "svg", "strong", "em",
}
# <link rel=...> values that make the browser fetch something.
LOADING_RELS = {"stylesheet", "icon", "preload", "modulepreload", "manifest", "apple-touch-icon",
                "prefetch", "preconnect", "dns-prefetch", "mask-icon"}
NETWORK_JS = re.compile(r"\b(fetch\s*\(|XMLHttpRequest|sendBeacon|new\s+WebSocket|EventSource|import\s*\()")
CSS_URL = re.compile(r"""url\(\s*['"]?([^'")]+)['"]?\s*\)|@import\s+['"]([^'"]+)['"]""")

errors: list[str] = []


def err(path: Path, msg: str) -> None:
    errors.append(f"{path}: {msg}")


class Page(HTMLParser):
    def __init__(self, path: Path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.stack: list[tuple[str, int]] = []
        self.ids: dict[str, int] = {}
        self.refs: list[tuple[str, str, int]] = []      # (attr, url, line)
        self.loads: list[tuple[str, str, int]] = []     # resources the browser fetches
        self.fragments: list[tuple[str, int]] = []
        self.html_lang = False
        self.title = ""
        self.in_title = False
        self.in_script = False
        self.script_is_js = False
        self.scripts: list[tuple[str, int]] = []
        self.anchor_hrefs: list[str] = []

    def handle_starttag(self, tag, attrs):
        self._tag(tag, attrs, selfclosing=False)

    def handle_startendtag(self, tag, attrs):
        self._tag(tag, attrs, selfclosing=True)

    def _tag(self, tag, attrs, selfclosing):
        line = self.getpos()[0]
        a = {k: (v or "") for k, v in attrs}
        if tag in MUST_CLOSE and not selfclosing:
            self.stack.append((tag, line))
        if tag == "html" and a.get("lang"):
            self.html_lang = True
        if "id" in a:
            if a["id"] in self.ids:
                err(self.path, f"line {line}: duplicate id '{a['id']}' (first on line {self.ids[a['id']]})")
            self.ids.setdefault(a["id"], line)
        if tag == "title":
            self.in_title = True
        if tag == "script":
            self.in_script = True
            self.script_is_js = a.get("type", "text/javascript") in {"", "text/javascript", "module"}
        for attr in ("src", "href", "poster", "data"):
            if attr in a:
                self.refs.append((attr, a[attr], line))
        if "srcset" in a:
            for part in a["srcset"].split(","):
                url = part.strip().split(" ")[0]
                if url:
                    self.refs.append(("srcset", url, line))
                    self.loads.append((tag, url, line))
        if tag in {"script", "img", "source", "video", "audio", "iframe", "embed", "track"} and a.get("src"):
            self.loads.append((tag, a["src"], line))
        if tag == "object" and a.get("data"):
            self.loads.append((tag, a["data"], line))
        if tag == "link":
            rels = set(a.get("rel", "").lower().split())
            if rels & LOADING_RELS and a.get("href"):
                self.loads.append((f"link rel={a.get('rel')}", a["href"], line))
        if tag == "a" and a.get("href"):
            self.anchor_hrefs.append(a["href"])
        if a.get("href", "").startswith("#") and len(a["href"]) > 1:
            self.fragments.append((a["href"][1:], line))
        if "style" in a:
            for m in CSS_URL.finditer(a["style"]):
                url = m.group(1) or m.group(2)
                self.refs.append(("style url()", url, line))
                self.loads.append(("style url()", url, line))

    def handle_endtag(self, tag):
        line = self.getpos()[0]
        if tag == "title":
            self.in_title = False
        if tag == "script":
            self.in_script = False
        if tag not in MUST_CLOSE:
            return
        if not self.stack:
            err(self.path, f"line {line}: </{tag}> with nothing open")
            return
        open_tag, open_line = self.stack[-1]
        if open_tag == tag:
            self.stack.pop()
            return
        # Tolerate tags implicitly closed inside svg (path etc. aren't tracked).
        err(self.path, f"line {line}: </{tag}> closes <{open_tag}> opened on line {open_line}")
        # Recover: pop to the matching tag if it's further down.
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self.in_script and self.script_is_js and data.strip():
            self.scripts.append((data, self.getpos()[0]))


def own_hosts(site: Path) -> set[str]:
    cname = site / "CNAME"
    hosts = set()
    if cname.exists():
        host = cname.read_text().strip().lower()
        if host:
            hosts.add(host)
    return hosts


def resolve_local(site: Path, page: Path, url: str, hosts: set[str]) -> Path | None:
    """Return the file a URL points at inside site/, or None if it isn't local."""
    url = url.strip()
    if not url or url.startswith(("#", "mailto:", "tel:", "data:", "javascript:")):
        return None
    parts = urlsplit(url)
    if parts.scheme in {"http", "https"} or url.startswith("//"):
        if parts.hostname and parts.hostname.lower() in hosts:
            path = unquote(parts.path) or "/"
            target = site / path.lstrip("/")
        else:
            return None
    elif parts.scheme:
        return None
    else:
        path = unquote(parts.path)
        if not path:
            return None
        target = (site / path.lstrip("/")) if path.startswith("/") else (page.parent / path)
    if target.is_dir() or str(target).endswith("/"):
        target = target / "index.html"
    return target


def is_third_party(url: str, hosts: set[str]) -> bool:
    parts = urlsplit(url.strip())
    if parts.scheme in {"http", "https"} or url.strip().startswith("//"):
        return (parts.hostname or "").lower() not in hosts
    return False


def main() -> int:
    site = Path(sys.argv[1] if len(sys.argv) > 1 else "site").resolve()
    if not site.is_dir():
        print(f"no such directory: {site}", file=sys.stderr)
        return 2
    hosts = own_hosts(site)
    files = sorted(p for p in site.rglob("*") if p.is_file())
    html_files = [p for p in files if p.suffix == ".html"]
    if not html_files:
        err(site, "no .html files found")

    # Text-wide checks.
    for path in files:
        if path.suffix not in TEXT_SUFFIXES and path.name != "CNAME":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if "/Users/" in text:
            err(path, "contains a local developer path ('/Users/')")
        visible = re.sub(r"<!--.*?-->", "", text, flags=re.S) if path.suffix == ".html" else text
        if "YOUR_USERNAME" in visible:
            err(path, "YOUR_USERNAME placeholder outside an HTML comment")

    # HTML structure, references and network promise.
    for path in html_files:
        raw = path.read_text(encoding="utf-8")
        page = Page(path)
        page.feed(raw)
        page.close()
        for tag, line in page.stack:
            err(path, f"line {line}: <{tag}> never closed")
        if not page.html_lang:
            err(path, "<html> has no lang attribute")
        if not page.title.strip():
            err(path, "missing or empty <title>")
        for frag, line in page.fragments:
            if frag not in page.ids:
                err(path, f"line {line}: link to #{frag} but no element has that id")
        for attr, url, line in page.refs:
            target = resolve_local(site, path, url, hosts)
            if target is not None and not target.exists():
                err(path, f"line {line}: {attr}='{url}' points at a missing file ({target.relative_to(site) if site in target.parents else target})")
        for what, url, line in page.loads:
            if is_third_party(url, hosts):
                err(path, f"line {line}: {what} loads '{url}' from another host; the site promises no third-party requests")
        for code, line in page.scripts:
            m = NETWORK_JS.search(code)
            if m:
                err(path, f"script near line {line}: '{m.group(1)}' makes a network request; the site promises it loads nothing from other servers")
        if path.name == "index.html":
            if STABLE_DMG_URL not in page.anchor_hrefs:
                err(path, f"no download link to the stable URL {STABLE_DMG_URL}")
            if raw.count("<h1") != 1:
                err(path, "expected exactly one <h1>")

    # CSS url() references and third-party loads.
    for path in (p for p in files if p.suffix == ".css"):
        text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
        for m in CSS_URL.finditer(text):
            url = m.group(1) or m.group(2)
            line = text.count("\n", 0, m.start()) + 1
            if is_third_party(url, hosts):
                err(path, f"line {line}: loads '{url}' from another host")
                continue
            target = resolve_local(site, path, url, hosts)
            if target is not None and not target.exists():
                err(path, f"line {line}: url('{url}') points at a missing file")

    # Web app manifest icons.
    for path in (p for p in files if p.suffix == ".webmanifest"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            err(path, f"invalid JSON: {e}")
            continue
        for icon in data.get("icons", []):
            target = resolve_local(site, path, icon.get("src", ""), hosts)
            if target is not None and not target.exists():
                err(path, f"icon '{icon.get('src')}' points at a missing file")

    if errors:
        print(f"site check FAILED ({len(errors)} problem(s)):")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"site check ok: {len(html_files)} HTML file(s), {len(files)} file(s) in {site}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
