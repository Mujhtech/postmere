#!/usr/bin/env bash
# Packages Postmere.app into the branded drag-to-install disk image.
#
#   script/make_dmg.sh path/to/Postmere.app path/to/Postmere-1.2.0.dmg
#
# Signing and notarizing the image is left to script/release.sh.
set -euo pipefail

app="${1:?Usage: script/make_dmg.sh <Postmere.app> <output.dmg>}"
output="${2:?Usage: script/make_dmg.sh <Postmere.app> <output.dmg>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/dmg"
venv="$root/build/dmg-venv"
mkdir -p "$work"

# dmgbuild writes the Finder layout directly, so no Finder scripting or
# Automation permission is needed. Pinned and kept out of the repository.
if [[ ! -x "$venv/bin/dmgbuild" ]]; then
    echo "› Installing dmgbuild"
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet "dmgbuild==1.6.7"
fi

echo "› Drawing background"
swift "$root/script/dmg/background.swift" "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" 2>/dev/null

echo "› Building $(basename "$output")"
rm -f "$output"
"$venv/bin/dmgbuild" -s "$root/script/dmg/settings.py" \
    -D app="$app" -D background_dir="$work" "Postmere" "$output"
