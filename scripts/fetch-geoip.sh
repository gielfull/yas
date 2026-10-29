#!/usr/bin/env bash
# Download the current month's DB-IP Lite Country database (CC BY 4.0,
# https://db-ip.com) into YAS/Resources/GeoIP/, where the app bundles it.
# Re-run `xcodegen generate` afterwards so the new file is picked up.
#
# DB-IP publishes a new file at the start of each month; if the current month is
# not up yet, fall back to the previous one.
set -euo pipefail
cd "$(dirname "$0")/.."

dest_dir="YAS/Resources/GeoIP"
dest="$dest_dir/dbip-country-lite.mmdb"
mkdir -p "$dest_dir"

tmp="$(mktemp -t dbip-country-lite)"
trap 'rm -f "$tmp" "$tmp.mmdb"' EXIT

fetch() {
  local month="$1"
  local url="https://download.db-ip.com/free/dbip-country-lite-${month}.mmdb.gz"
  echo "Downloading $url"
  curl --fail --silent --show-error --location --output "$tmp" "$url"
}

this_month="$(date -u +%Y-%m)"
last_month="$(date -u -v-1m +%Y-%m 2>/dev/null || date -u -d '1 month ago' +%Y-%m)"

if ! fetch "$this_month"; then
  echo "Not available yet, trying $last_month"
  fetch "$last_month"
fi

gunzip -c "$tmp" > "$tmp.mmdb"
# Sanity check: every MaxMind DB ends with the metadata marker.
if ! LC_ALL=C grep -q "MaxMind.com" "$tmp.mmdb"; then
  echo "Downloaded file is not a MaxMind DB" >&2
  exit 1
fi
mv "$tmp.mmdb" "$dest"
echo "Saved $dest ($(du -h "$dest" | cut -f1))"
