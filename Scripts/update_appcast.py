#!/usr/bin/env python3
# update_appcast.py — Prepend a new release entry to appcast.xml
#
# Usage:
#   python3 Scripts/update_appcast.py <appcast.xml> <version> <sparkle_version> \
#       <pub_date> <ed_sig> <length> [notes.md]
#
# Arguments:
#   appcast.xml      Path to the appcast file to update
#   version          Marketing version string (e.g. 1.0.7)
#   sparkle_version  Integer build counter (e.g. 7)
#   pub_date         RFC 2822 UTC date string (e.g. "Thu, 18 Apr 2026 12:00:00 +0000")
#   ed_sig           EdDSA signature from sign_update
#   length           Byte size of the DMG
#   notes.md         Optional — path to markdown file for release notes
#                    If omitted, a placeholder is inserted.

import sys
import re
import argparse
import html
from urllib.parse import urlparse, quote


def markdown_to_html(path):
    with open(path) as f:
        lines = f.read().splitlines()

    out = []
    in_ul = False
    for line in lines:
        if line.startswith('## '):
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<h3>{line[3:].strip()}</h3>')
        elif re.match(r'^[-*] ', line):
            if not in_ul:
                out.append('<ul>')
                in_ul = True
            item = line[2:].strip()
            item = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', item)
            out.append(f'<li>{item}</li>')
        elif line.strip():
            if in_ul:
                out.append('</ul>')
                in_ul = False
            out.append(f'<p>{line.strip()}</p>')

    if in_ul:
        out.append('</ul>')
    return '\n        '.join(out)


def main():
    parser = argparse.ArgumentParser(description="Prepare an OpenEmu-NX signed appcast entry.")
    parser.add_argument("appcast")
    parser.add_argument("version")
    parser.add_argument("sparkle_version", type=int)
    parser.add_argument("pub_date")
    parser.add_argument("ed_sig")
    parser.add_argument("length", type=int)
    parser.add_argument("notes", nargs="?")
    parser.add_argument("--repo", default="csilvertooth/OpenEmu-NX")
    parser.add_argument("--artifact-base", help="Owned HTTPS download directory; defaults to the repository release tag")
    parser.add_argument("--artifact-name", default="OpenEmu-NX.dmg")
    parser.add_argument("--new-feed", action="store_true", help="Create a clean owned feed; refuses to overwrite an existing file")
    args = parser.parse_args()
    if not re.fullmatch(r"csilvertooth/[A-Za-z0-9_.-]+", args.repo):
        parser.error("--repo must be an owned csilvertooth repository")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("version must use X.Y.Z")
    if args.sparkle_version < 1 or args.length < 1:
        parser.error("build number and artifact length must be positive")
    if '/' in args.artifact_name or '\\' in args.artifact_name or not args.artifact_name:
        parser.error("--artifact-name must be a filename")
    base = args.artifact_base or f"https://github.com/{args.repo}/releases/download/v{args.version}"
    parsed = urlparse(base)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        parser.error("--artifact-base must be an HTTPS URL without credentials")
    if 'openemu-silicon/openemu-silicon' in base.lower():
        parser.error("upstream release destinations are not allowed")
    appcast_path, version = args.appcast, args.version
    sparkle_version, pub_date = args.sparkle_version, html.escape(args.pub_date)
    ed_sig, length = html.escape(args.ed_sig, quote=True), args.length
    notes_file = args.notes
    artifact_url = html.escape(base.rstrip('/') + '/' + quote(args.artifact_name), quote=True)

    if notes_file:
        notes_html = markdown_to_html(notes_file)
    else:
        notes_html = '<p>TODO: add release notes before publishing.</p>'

    new_item = f"""    <item>
      <title>OpenEmu-NX {version}</title>
      <description>
        <![CDATA[
        <h2>OpenEmu-NX {version}</h2>
        {notes_html}
        ]]>
      </description>
      <pubDate>{pub_date}</pubDate>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure
        url="{artifact_url}"
        sparkle:version="{sparkle_version}"
        sparkle:shortVersionString="{version}"
        sparkle:edSignature="{ed_sig}"
        length="{length}"
        type="application/octet-stream"/>
    </item>"""

    if args.new_feed:
        # Exclusive creation below prevents an accidental replacement of a release feed.
        content = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenEmu-NX</title>
    <link>https://github.com/{args.repo}</link>
    <description>OpenEmu-NX signed releases</description>
    <language>en</language>
  </channel>
</rss>
'''
    else:
        with open(appcast_path, 'r') as f:
            content = f.read()
        if 'openemu-silicon/openemu-silicon' in content.lower():
            parser.error("existing appcast contains upstream URLs; use --new-feed with a new output path")

    insert_after = re.search(r'(<language>[^<]*</language>\s*)', content)
    if not insert_after:
        print('ERROR: could not find insertion point in appcast.xml', file=sys.stderr)
        sys.exit(1)

    pos = insert_after.end()
    content = content[:pos] + new_item + '\n' + content[pos:]

    with open(appcast_path, 'x' if args.new_feed else 'w') as f:
        f.write(content)

    print(f'Prepended v{version} entry (sparkle:version={sparkle_version}) to {appcast_path}')


if __name__ == '__main__':
    main()
