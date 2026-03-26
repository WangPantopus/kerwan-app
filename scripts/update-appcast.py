#!/usr/bin/env python3
"""
update-appcast.py
─────────────────
Prepends a new <item> into appcast.xml for the given release, then trims
the channel to at most MAX_ITEMS entries (oldest removed first).

Creates appcast.xml from scratch if it does not exist yet.

Usage
    python3 scripts/update-appcast.py \\
        <version>        e.g. 1.2.3
        <build_number>   monotonically increasing integer (CFBundleVersion)
        <eddsa_sig>      base64 EdDSA signature from Sparkle's sign_update
        <file_size>      DMG byte count
        <dmg_filename>   e.g. Kerwan-1.2.3.dmg
        [download_base_url]  default: https://releases.kerwan.app/releases
"""

import sys
import re
import pathlib
from datetime import datetime, timezone

# ── Configuration ────────────────────────────────────────────────────────────
APPCAST_PATH  = pathlib.Path("appcast.xml")
MAX_ITEMS     = 10          # keep the N most recent items
MIN_MACOS     = "13.0"      # sparkle:minimumSystemVersion

APPCAST_TEMPLATE = """\
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Kerwan Updates</title>
    <link>https://kerwan.app</link>
    <description>Most recent Kerwan changes with links to updates.</description>
    <language>en</language>
  </channel>
</rss>
"""

ITEM_TEMPLATE = """\
    <item>
      <title>Kerwan {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_macos}</sparkle:minimumSystemVersion>
      <enclosure
        url="{download_url}"
        type="application/x-apple-diskimage"
        sparkle:edSignature="{eddsa_sig}"
        length="{file_size}"/>
    </item>"""


def main() -> None:
    if len(sys.argv) < 6:
        print(__doc__)
        sys.exit(1)

    version, build_number, eddsa_sig, file_size, dmg_filename = sys.argv[1:6]
    download_base = sys.argv[6] if len(sys.argv) > 6 \
        else "https://releases.kerwan.app/releases"

    download_url = f"{download_base.rstrip('/')}/{dmg_filename}"

    # RFC-2822 date required by Sparkle
    now      = datetime.now(timezone.utc)
    pub_date = now.strftime("%a, %d %b %Y %H:%M:%S +0000")

    new_item = ITEM_TEMPLATE.format(
        version      = version,
        build_number = build_number,
        pub_date     = pub_date,
        min_macos    = MIN_MACOS,
        download_url = download_url,
        eddsa_sig    = eddsa_sig,
        file_size    = file_size,
    )

    # ── Read or initialise the appcast ──────────────────────────────────────
    if APPCAST_PATH.exists():
        content = APPCAST_PATH.read_text(encoding="utf-8")
    else:
        print(f"▸ {APPCAST_PATH} not found — creating from template")
        content = APPCAST_TEMPLATE

    # ── Find insertion point (after the last header element inside <channel>)
    # We insert right before the first existing <item> or before </channel>
    FIRST_ITEM_RE = re.compile(r"(\s*<item>)", re.MULTILINE)
    CHANNEL_CLOSE = "</channel>"

    m = FIRST_ITEM_RE.search(content)
    if m:
        insert_at = m.start()
    else:
        insert_at = content.index(CHANNEL_CLOSE)

    content = content[:insert_at] + "\n" + new_item + "\n" + content[insert_at:]

    # ── Trim to MAX_ITEMS ────────────────────────────────────────────────────
    item_pattern = re.compile(r"\n    <item>.*?</item>", re.DOTALL)
    items = item_pattern.findall(content)

    if len(items) > MAX_ITEMS:
        surplus = items[MAX_ITEMS:]
        for old in surplus:
            content = content.replace(old, "", 1)
        print(f"▸ Trimmed {len(surplus)} old item(s) (keeping {MAX_ITEMS})")

    # ── Write back ───────────────────────────────────────────────────────────
    APPCAST_PATH.write_text(content, encoding="utf-8")
    print(f"▸ appcast.xml updated — version {version} (build {build_number})")
    print(f"  Download: {download_url}")
    print(f"  EdDSA:    {eddsa_sig[:20]}…")


if __name__ == "__main__":
    main()
