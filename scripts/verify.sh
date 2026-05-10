#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
DMG_PATH="$ROOT/dist/STFU-$VERSION.dmg"
PKG_PATH="$ROOT/dist/STFU-$VERSION.pkg"

if [[ "${VERIFY_EXISTING:-0}" == "1" ]]; then
  swift build --package-path "$ROOT" -c release
else
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

shasum -a 256 "$DMG_PATH" "$PKG_PATH"

if [[ "${STRICT_SIGNING:-0}" == "1" ]]; then
  spctl -a -vv -t open "$DMG_PATH"
  spctl -a -vv -t install "$PKG_PATH"
else
  spctl -a -vv -t open "$DMG_PATH" || true
  spctl -a -vv -t install "$PKG_PATH" || true
fi
