#!/bin/bash
#
# Future-ready appcast.xml generator for AutoRipper.
#
# Generates a Sparkle 2-compatible appcast feed from the GitHub
# Releases API. Run after a successful build-swift.sh release to
# regenerate the feed. Eventually this gets called from
# build-swift.sh itself once the Sparkle integration lands; see
# Updates/SPARKLE.md for the full roadmap.
#
# Until then, this is unwired scaffolding — running it produces a
# valid appcast.xml but nothing in the app consumes it yet.
#
# Usage:
#   ./Updates/generate-appcast.sh > Updates/appcast.xml
#
# Requirements:
#   - jq (brew install jq)
#   - curl
#   - Optional: Sparkle's sign_update binary in $PATH for EdDSA
#     signatures. Without it, enclosures are unsigned (fine for
#     testing, not for production).

set -euo pipefail

REPO="stevenob/AutoRipper"
FEED_TITLE="AutoRipper updates"
FEED_LINK="https://github.com/${REPO}"

cat <<HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${FEED_TITLE}</title>
    <link>${FEED_LINK}</link>
    <description>AutoRipper release feed</description>
    <language>en</language>
HEADER

# Fetch releases, newest first. Skip pre-releases for Sparkle's
# default channel (a /beta channel could be added later).
curl -s "https://api.github.com/repos/${REPO}/releases?per_page=20" \
    | jq -r '.[]
        | select(.prerelease == false)
        | "\(.tag_name)\t\(.published_at)\t\(.html_url)\t\((.assets[] | select(.name | endswith(".dmg")) | .browser_download_url) // "")\t\((.assets[] | select(.name | endswith(".dmg")) | .size) // 0)\t\(.body | gsub("\\n"; " \\\\n "))"' \
    | while IFS=$'\t' read -r tag pubDate htmlUrl dmgUrl dmgSize body; do
        # Skip releases without a DMG asset
        [ -z "$dmgUrl" ] && continue
        version="${tag#v}"
        # Convert ISO8601 to RFC822 for RSS
        pubDateRFC=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pubDate" "+%a, %d %b %Y %H:%M:%S %z" 2>/dev/null || echo "$pubDate")
        # EdDSA signature (empty when sign_update is unavailable)
        sig=""
        if command -v sign_update >/dev/null 2>&1 && [ -f "$dmgUrl" ]; then
            sig=$(sign_update "$dmgUrl" 2>/dev/null || echo "")
        fi
        cat <<ITEM
    <item>
      <title>${tag}</title>
      <link>${htmlUrl}</link>
      <sparkle:version>${version}</sparkle:version>
      <pubDate>${pubDateRFC}</pubDate>
      <description><![CDATA[${body}]]></description>
      <enclosure
        url="${dmgUrl}"
        length="${dmgSize}"
        type="application/octet-stream"${sig:+
        $sig}/>
    </item>
ITEM
    done

cat <<FOOTER
  </channel>
</rss>
FOOTER
