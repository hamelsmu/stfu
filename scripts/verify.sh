#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
DMG_PATH="$ROOT/dist/STFU-$VERSION.dmg"
PKG_PATH="$ROOT/dist/STFU-$VERSION.pkg"

echo "Running unit tests."
swift test --package-path "$ROOT"

if [[ "${VERIFY_EXISTING:-0}" == "1" ]]; then
  echo "Verifying existing artifacts for VERSION=$VERSION; package rebuild is skipped."
  swift build --package-path "$ROOT" -c release
else
  echo "Building artifacts for VERSION=$VERSION before verification."
  VERSION="$VERSION" "$ROOT/scripts/package.sh"
fi

if [[ ! -f "$DMG_PATH" || ! -f "$PKG_PATH" ]]; then
  echo "Missing packaged artifacts for VERSION=$VERSION. Run VERSION=$VERSION scripts/package.sh first or unset VERIFY_EXISTING to rebuild." >&2
  exit 1
fi

echo "Verifying DMG integrity: $DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "Checking package payload for AppleDouble metadata: $PKG_PATH"
if pkgutil --payload-files "$PKG_PATH" | grep --color=never -E '(^|/)\._[^/]*$'; then
  echo "Package payload contains AppleDouble metadata files." >&2
  exit 1
fi

echo "SHA-256 checksums:"
shasum -a 256 "$DMG_PATH" "$PKG_PATH"

if [[ "${STRICT_SIGNING:-0}" == "1" ]]; then
  echo "Running required Gatekeeper checks because STRICT_SIGNING=1."
  spctl -a -vv -t open "$DMG_PATH"
  spctl -a -vv -t install "$PKG_PATH"
else
  echo "Running advisory Gatekeeper checks. Set STRICT_SIGNING=1 to fail on signing or notarization rejection."
  spctl -a -vv -t open "$DMG_PATH" || true
  spctl -a -vv -t install "$PKG_PATH" || true
fi
