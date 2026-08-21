#!/bin/bash
# Installs card artwork into the running simulator's card-art folder.
#
#   ./add-art.sh <image> <CARD-ID>     install one image for one card
#   ./add-art.sh <folder>              install every image in a folder,
#                                      matched to cards by filename
#   ./add-art.sh --list                show what is currently installed
#   ./add-art.sh --open                reveal the art folder in Finder
#
# Card art is never committed to this repo — see .gitignore and CARD_DATA.md.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

BUNDLE_ID="com.practiceMakesPerfect.personalProjects.NTCGSimulator"

udid=$(xcrun simctl list devices booted 2>/dev/null \
       | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$udid" ]; then
  echo "No booted simulator. Start one, then run ./build.sh run" >&2
  exit 1
fi

container=$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null) || {
  echo "App is not installed on the booted simulator. Run ./build.sh run first." >&2
  exit 1
}
art="$container/Library/Application Support/CardArt"
mkdir -p "$art"

case "${1:-}" in
  --list)
    echo "Installed artwork in:"; echo "  $art"; echo
    ls -1 "$art" 2>/dev/null || echo "  (empty)"
    exit 0 ;;
  --open)
    open "$art"; exit 0 ;;
  "")
    sed -n '2,10p' "$0" | sed 's|^# \{0,1\}||'; exit 1 ;;
esac

install_one() {   # $1 = source file, $2 = card id
  local src="$1" id="$2"
  local ext="${src##*.}"
  rm -f "$art/$id".*                      # replace any existing art for this card
  cp "$src" "$art/$id.$ext"
  echo "  $id  <-  $(basename "$src")"
}

if [ -d "$1" ]; then
  echo "Installing every image in $1"
  count=0
  # Filename stem is taken as the card id, e.g. N-004.png -> N-004
  while IFS= read -r -d '' f; do
    stem=$(basename "$f"); stem="${stem%.*}"
    install_one "$f" "$stem"; count=$((count + 1))
  done < <(find "$1" -maxdepth 1 -type f \
             \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
                -o -iname '*.webp' -o -iname '*.heic' \) -print0)
  echo "Installed $count image(s)."
else
  [ -f "$1" ] || { echo "No such file: $1" >&2; exit 1; }
  [ -n "${2:-}" ] || { echo "Give the card id, e.g. ./add-art.sh naruto.png N-004" >&2; exit 1; }
  echo "Installing artwork:"
  install_one "$1" "$2"
fi

echo
echo "Relaunching the app so it picks the art up..."
xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
echo "Done."
