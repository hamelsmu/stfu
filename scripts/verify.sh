#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.1}"
DMG_PATH="$ROOT/dist/STFU-$VERSION.dmg"
PKG_PATH="$ROOT/dist/STFU-$VERSION.pkg"

echo "Running Swift tests..."
swift test --package-path "$ROOT"

if [[ "${VERIFY_EXISTING:-0}" == "1" ]]; then
  echo "Verifying existing artifacts for VERSION=$VERSION..."
  swift build --package-path "$ROOT" -c release
else
  echo "Building package artifacts for VERSION=$VERSION..."
  VERSION="$VERSION" "$ROOT/scripts/package.sh"
fi

if [[ ! -f "$DMG_PATH" || ! -f "$PKG_PATH" ]]; then
  echo "Missing packaged artifacts for VERSION=$VERSION." >&2
  exit 1
fi

hdiutil verify "$DMG_PATH"

if pkgutil --payload-files "$PKG_PATH" | grep --color=never -E '(^|/)\._[^/]*$'; then
  echo "Package payload contains AppleDouble metadata files." >&2
  exit 1
fi

payload_files="$(pkgutil --payload-files "$PKG_PATH")"
required_payload_files=(
  "./Applications/STFU.app/Contents/MacOS/stfu"
  "./usr/local/bin/stfu"
)

for required in "${required_payload_files[@]}"; do
  if ! grep -Fxq "$required" <<<"$payload_files"; then
    echo "Package payload is missing $required." >&2
    exit 1
  fi
done

if grep -Fq "./Applications/STFU Menu.app" <<<"$payload_files"; then
  echo "Package payload should not include the old separate STFU Menu.app bundle." >&2
  exit 1
fi

shasum -a 256 "$DMG_PATH" "$PKG_PATH"

if [[ "${STRICT_SIGNING:-0}" == "1" ]]; then
  echo "Running strict Gatekeeper checks..."
  spctl -a -vv -t open "$DMG_PATH"
  spctl -a -vv -t install "$PKG_PATH"
else
  echo "Running advisory Gatekeeper checks. Set STRICT_SIGNING=1 to fail on rejection."
  spctl -a -vv -t open "$DMG_PATH" || echo "Advisory: DMG is not accepted by Gatekeeper in this local build."
  spctl -a -vv -t install "$PKG_PATH" || echo "Advisory: PKG is not accepted by Gatekeeper in this local build."
fi
