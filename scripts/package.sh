#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
IDENTIFIER="${IDENTIFIER:-dev.hamel.stfu}"
APP_NAME="STFU"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-$IDENTIFIER}"
INSTALLER_IDENTIFIER="${INSTALLER_IDENTIFIER:-$IDENTIFIER.installer}"
DIST_DIR="$ROOT/dist"
WORK_DIR="$ROOT/.build/installer"
PAYLOAD_DIR="$WORK_DIR/payload"
SCRIPTS_DIR="$WORK_DIR/scripts"
DMG_ROOT="$WORK_DIR/dmg-root"
ICON_PATH="$WORK_DIR/STFU.icns"
DEFAULT_ARTWORK_PATH="$ROOT/assets/pulpfiction_new.webp"
ARTWORK_PATH="${ARTWORK_PATH:-$DEFAULT_ARTWORK_PATH}"
APP_BUNDLE="$PAYLOAD_DIR/Applications/$APP_NAME.app"
PKG_PATH="$DIST_DIR/STFU-$VERSION.pkg"
RAW_PKG_PATH="$WORK_DIR/STFU-$VERSION.raw.pkg"
UNSIGNED_PKG_PATH="$WORK_DIR/STFU-$VERSION.unsigned.pkg"
DMG_PATH="$DIST_DIR/STFU-$VERSION.dmg"

clear_extended_attributes() {
  local path="$1"

  if command -v xattr >/dev/null 2>&1; then
    find "$path" -depth -exec xattr -c {} + 2>/dev/null || true
  fi
}

rm -rf "$WORK_DIR"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources" \
  "$PAYLOAD_DIR/usr/local/bin" \
  "$SCRIPTS_DIR" \
  "$DMG_ROOT" \
  "$DIST_DIR"

swift build --package-path "$ROOT" -c release
if [[ -f "$ARTWORK_PATH" ]]; then
  "$ROOT/scripts/make-icon.swift" "$ICON_PATH" "$ARTWORK_PATH"
else
  "$ROOT/scripts/make-icon.swift" "$ICON_PATH"
fi

install -m 755 "$ROOT/.build/release/stfu" "$APP_BUNDLE/Contents/MacOS/stfu"
cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/STFU.icns"
if [[ -f "$ARTWORK_PATH" ]]; then
  cp "$ARTWORK_PATH" "$APP_BUNDLE/Contents/Resources/pulpfiction_new.webp"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>STFU</string>
  <key>CFBundleExecutable</key>
  <string>stfu</string>
  <key>CFBundleIconFile</key>
  <string>STFU</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>STFU</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>STFU sends Apple events to close noisy browser tabs after macOS identifies the app producing sound.</string>
</dict>
</plist>
PLIST

cat > "$PAYLOAD_DIR/usr/local/bin/stfu" <<'WRAPPER'
#!/bin/sh
exec /Applications/STFU.app/Contents/MacOS/stfu "$@"
WRAPPER
chmod 755 "$PAYLOAD_DIR/usr/local/bin/stfu"

cat > "$SCRIPTS_DIR/postinstall" <<'POSTINSTALL'
#!/bin/sh
exit 0
POSTINSTALL
chmod 755 "$SCRIPTS_DIR/postinstall"

find "$PAYLOAD_DIR" -name '._*' -delete
clear_extended_attributes "$PAYLOAD_DIR"

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$APP_SIGN_IDENTITY" "$APP_BUNDLE"

find "$PAYLOAD_DIR" -name '._*' -delete
clear_extended_attributes "$PAYLOAD_DIR"

PKGBUILD_ARGS=(
  --root "$PAYLOAD_DIR"
  --scripts "$SCRIPTS_DIR"
  --identifier "$INSTALLER_IDENTIFIER"
  --version "$VERSION"
  --install-location "/"
  --filter '\.DS_Store$'
  --filter '(^|/)\.svn($|/)'
  --filter '(^|/)CVS($|/)'
  --filter '(^|/)\._[^/]*$'
)

pkgbuild "${PKGBUILD_ARGS[@]}" "$RAW_PKG_PATH"

NORMALIZED_PKG_DIR="$WORK_DIR/normalized-pkg"
rm -rf "$NORMALIZED_PKG_DIR"
mkdir -p "$NORMALIZED_PKG_DIR"
(
  cd "$NORMALIZED_PKG_DIR"
  xar -xf "$RAW_PKG_PATH"
)
mkbom "$PAYLOAD_DIR" "$NORMALIZED_PKG_DIR/Bom"
(
  cd "$PAYLOAD_DIR"
  find . ! -name '._*' -print | LC_ALL=C sort | cpio -o --format odc 2>/dev/null | gzip -c > "$NORMALIZED_PKG_DIR/Payload"
)
rm -f "$UNSIGNED_PKG_PATH" "$PKG_PATH"
(
  cd "$NORMALIZED_PKG_DIR"
  xar --compression none -cf "$UNSIGNED_PKG_PATH" Bom PackageInfo Payload Scripts
)

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  productsign --sign "$SIGN_IDENTITY" "$UNSIGNED_PKG_PATH" "$PKG_PATH"
else
  cp "$UNSIGNED_PKG_PATH" "$PKG_PATH"
fi

if pkgutil --payload-files "$PKG_PATH" | grep --color=never -E '(^|/)\._[^/]*$'; then
  echo "Package payload contains AppleDouble metadata files." >&2
  exit 1
fi

cp "$PKG_PATH" "$DMG_ROOT/Install STFU.pkg"
cp "$ICON_PATH" "$DMG_ROOT/.VolumeIcon.icns"
cat > "$DMG_ROOT/README.txt" <<README
STFU

Find the app or browser tab making noise and make it STFU.

1. Open "Install STFU.pkg".
2. Open STFU.
3. If a browser row says it needs Accessibility, click "Open Settings".
4. In System Settings > Privacy & Security > Accessibility, turn on STFU.

Unsigned build: if macOS blocks the installer, Control-click it and choose Open.
Accessibility lets STFU see browser tabs so it can close the noisy tab instead of the whole browser.
macOS may also ask for Automation permission when STFU controls a browser.

To check setup from Terminal, run:
  stfu --doctor

The installer adds:
- /Applications/STFU.app
- /usr/local/bin/stfu
README

SetFile -a C "$DMG_ROOT" || true
rm -f "$DMG_PATH"
hdiutil create \
  -volname "STFU" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ -n "${DMG_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "$PKG_PATH"
echo "$DMG_PATH"
