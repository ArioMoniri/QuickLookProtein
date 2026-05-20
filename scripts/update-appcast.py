#!/usr/bin/env python3
"""
update-appcast.py — append a new release entry to docs/appcast.xml.

Called by .github/workflows/release.yml after the .zip is signed and
uploaded. Idempotent: if an entry for the same version already exists, it's
replaced rather than duplicated (so re-runs of the workflow on the same tag
don't accumulate stale entries).

Why a Python script and not awk/sed:
  appcast.xml is XML with mixed Sparkle / RSS namespaces. Hand-rolling a
  text mutation would either be fragile (regex over XML) or way too long
  to maintain. `xml.etree.ElementTree` is in the stdlib on GitHub's macOS
  runners and handles the namespace correctly.
"""
from __future__ import annotations

import argparse
import html
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def extract_changelog_section(changelog_path: Path, version: str) -> str | None:
    """
    Pull the `## [<version>] — …` section out of CHANGELOG.md and return
    its body (everything up to the next H2). Returns None if the version
    isn't found. The result is raw markdown - the caller is responsible
    for rendering / escaping.
    """
    if not changelog_path.exists():
        return None
    text = changelog_path.read_text(encoding="utf-8")
    # Match "## [1.7.67]" allowing optional trailing date / dashes.
    pattern = re.compile(
        rf"^## \[{re.escape(version)}\][^\n]*\n(?P<body>.*?)(?=^## \[|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        return None
    return m.group("body").strip()


def markdown_to_html(md: str) -> str:
    """
    Render a *small subset* of CommonMark inline into Sparkle-safe HTML.
    Sparkle's release-notes view is a WebKit web view, so anything CSS-
    free and clean works. We deliberately don't pull `markdown` or
    `mistune` as deps - keeping this stdlib-only matches the rest of
    the workflow's tooling story.

    Supported:
      - H3 (`### foo`)              -> <h3>
      - Bullet list (`- foo`)       -> <ul><li>
      - **bold** and `code` inline
      - Paragraphs separated by blank lines
      - Inline [text](url) links
    """
    out: list[str] = []
    in_list = False

    def flush_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    def inline(s: str) -> str:
        s = html.escape(s)
        # **bold**
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        # `code`
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        # [text](url)
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                   r'<a href="\2">\1</a>', s)
        return s

    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush_list()
            continue
        if line.startswith("### "):
            flush_list()
            out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
        elif line.startswith("## "):
            # Should never happen because extract_changelog_section
            # stops before the next H2, but guard anyway.
            flush_list()
            out.append(f"<h2>{inline(line[3:])}</h2>")
        else:
            flush_list()
            out.append(f"<p>{inline(line)}</p>")
    flush_list()
    return "\n".join(out)


def build_description(*, version: str, release_url: str,
                      changelog_path: Path) -> str:
    """
    Build the HTML payload for the <description> element. Sparkle 2.x
    accepts HTML escaped via CDATA *or* via XML entity encoding; we use
    entity encoding (ElementTree's default behaviour) so the appcast
    diffs cleanly in PRs.

    If we can pull the CHANGELOG section for this version, render that;
    otherwise fall back to a "See the GitHub release" stub so the
    dialog never paints empty.
    """
    md = extract_changelog_section(changelog_path, version)
    if md is None:
        return (
            f"<p>See <a href=\"{release_url}\">the GitHub release</a> for "
            f"full notes and the binary download.</p>"
        )

    rendered = markdown_to_html(md)
    footer = (
        f"<p style=\"margin-top:1em;font-size:smaller;color:#888;\">"
        f"Full release on "
        f"<a href=\"{release_url}\">GitHub</a>.</p>"
    )
    return rendered + "\n" + footer


def parse_signature_line(line: str) -> tuple[str, str | None]:
    """`sign_update` outputs e.g.

        sparkle:edSignature="ABC..." length="12345"

    Pull out the signature value and (optional) length. The workflow also
    passes us a length computed via stat(1) which we prefer because
    sign_update on some Sparkle versions omits it.
    """
    sig_m = re.search(r'sparkle:edSignature="([^"]+)"', line)
    if not sig_m:
        raise ValueError(f"Could not parse signature from line: {line!r}")
    len_m = re.search(r'length="(\d+)"', line)
    return sig_m.group(1), len_m.group(1) if len_m else None


def build_item(*, version: str, asset_url: str, release_url: str,
               edsig: str, length: str,
               changelog_path: Path) -> ET.Element:
    item = ET.Element("item")

    # "QuickLookProtein2" is the rebranded marketing name shown in
    # Sparkle's update dialog. The Sparkle comparator still keys off
    # <sparkle:version> below, not the title, so this is a pure
    # display change. Past appcast items keep their historical
    # "QuickLookProtein N.N.N" titles - we only rebrand new entries.
    ET.SubElement(item, "title").text = f"QuickLookProtein2 {version}"
    ET.SubElement(item, "link").text = release_url
    ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )

    sp_version = ET.SubElement(item, f"{{{SPARKLE_NS}}}version")
    sp_version.text = version
    sp_short = ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString")
    sp_short.text = version
    sp_min = ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion")
    sp_min.text = "11.0"

    # Render the version's CHANGELOG.md section as HTML so Sparkle's
    # WebKit notes pane shows the actual changelog instead of an empty
    # placeholder. Falls back to the historic "See the GitHub release"
    # stub if the version isn't found in CHANGELOG.md.
    desc = ET.SubElement(item, "description")
    desc.text = build_description(
        version=version,
        release_url=release_url,
        changelog_path=changelog_path,
    )

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", asset_url)
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", edsig)
    enclosure.set("length", length)
    enclosure.set("type", "application/octet-stream")

    return item


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast",  required=True)
    p.add_argument("--version",  required=True)
    p.add_argument("--asset-url", required=True)
    p.add_argument("--release-url", required=True)
    p.add_argument("--signature-line", required=True,
                   help='Output line from `sign_update`, e.g. '
                        'sparkle:edSignature="..." length="..."')
    p.add_argument("--length", required=True,
                   help="Fallback byte length if the signature line omits it.")
    p.add_argument("--changelog", default="CHANGELOG.md",
                   help="Path to CHANGELOG.md (relative to repo root). "
                        "The matching '## [<version>]' section becomes the "
                        "appcast <description>; missing entries fall back "
                        "to the GitHub-release-link stub.")
    args = p.parse_args()

    edsig, length_from_sig = parse_signature_line(args.signature_line)
    length = length_from_sig or args.length

    tree = ET.parse(args.appcast)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("appcast.xml is missing a <channel> element")

    # Remove any existing entry with the same sparkle:version (idempotent).
    for existing in list(channel.findall("item")):
        sp_ver = existing.find(f"{{{SPARKLE_NS}}}version")
        if sp_ver is not None and sp_ver.text == args.version:
            channel.remove(existing)

    # Insert the new item near the top of the channel (after metadata
    # elements: title, link, description, language) so the latest release
    # is closest to the feed root — Sparkle scans linearly.
    new_item = build_item(
        version=args.version,
        asset_url=args.asset_url,
        release_url=args.release_url,
        edsig=edsig,
        length=length,
        changelog_path=Path(args.changelog),
    )

    # Find the insertion index: after the last non-item child of channel.
    insert_at = 0
    for idx, child in enumerate(list(channel)):
        if child.tag != "item":
            insert_at = idx + 1
    channel.insert(insert_at, new_item)

    # ElementTree doesn't pretty-print by default; for diff-friendliness use
    # indent (Py3.9+) which the GitHub runner has.
    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"✓ Wrote new <item> for version {args.version} into {args.appcast}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
