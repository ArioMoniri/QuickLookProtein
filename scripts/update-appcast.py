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
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


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
               edsig: str, length: str) -> ET.Element:
    item = ET.Element("item")

    ET.SubElement(item, "title").text = f"QuickLookProtein {version}"
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

    desc = ET.SubElement(item, "description")
    desc.text = (
        f"<p>See <a href=\"{release_url}\">the GitHub release</a> for full "
        f"notes and the binary download.</p>"
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
