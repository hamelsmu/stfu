#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${VERSION:-0.1.0}}"
TAG="v$VERSION"
REPO="${REPO:-hamelsmu/stfu}"
DMG_PATH="$ROOT/dist/STFU-$VERSION.dmg"
PKG_PATH="$ROOT/dist/STFU-$VERSION.pkg"
NOTES_PATH="$ROOT/.build/release-notes-$VERSION.md"
FORCE="${FORCE:-0}"
DEFAULT_ARTWORK_PATH="$ROOT/assets/pulpfiction_new.webp"
REQUESTED_ARTWORK_PATH="${ARTWORK_PATH:-$DEFAULT_ARTWORK_PATH}"

cd "$ROOT"

CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "Release must run from main; current branch is '$CURRENT_BRANCH'." >&2
  exit 1
fi

if [[ -n "$(git status --short)" ]]; then
  echo "Working tree is dirty. Commit or stash changes before releasing." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required for release publishing." >&2
  exit 1
fi

gh auth status --hostname github.com >/dev/null
gh repo view "$REPO" --json name >/dev/null

case "$REQUESTED_ARTWORK_PATH" in
  "$DEFAULT_ARTWORK_PATH"|"$HOME/Downloads/pulpfiction_new.webp"|"assets/pulpfiction_new.webp"|*/pulpfiction_new.webp)
    if [[ "${ALLOW_PROTOTYPE_ARTWORK:-0}" != "1" ]]; then
      echo "Release would package prototype artwork that is not cleared for public redistribution." >&2
      echo "Set ARTWORK_PATH to cleared artwork, or set ALLOW_PROTOTYPE_ARTWORK=1 for a private/internal release." >&2
      exit 1
    fi
    ;;
esac

if [[ "$FORCE" != "1" ]]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Local tag $TAG already exists. Set FORCE=1 only when intentionally replacing it." >&2
    exit 1
  fi
  if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    echo "Remote tag $TAG already exists. Set FORCE=1 only when intentionally replacing it." >&2
    exit 1
  fi
fi

VERSION="$VERSION" "$ROOT/scripts/verify.sh"

git push origin main
if [[ "$FORCE" == "1" ]]; then
  git tag -f "$TAG" HEAD
  git push --force origin "$TAG"
else
  git tag "$TAG" HEAD
  git push origin "$TAG"
fi

DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
PKG_SHA="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"

mkdir -p "$(dirname "$NOTES_PATH")"
cat > "$NOTES_PATH" <<NOTES
Find the Mac app or browser tab making sound. Close that tab, quit that app, or silence everything.

![STFU app screenshot](https://github.com/$REPO/raw/$TAG/assets/screenshots/app-multiple-sources.png)

Download:
- \`STFU-$VERSION.dmg\` for the macOS installer disk image.

Install:
1. Open the DMG and run \`Install STFU.pkg\`.
2. Open STFU.
3. If a browser row asks for Accessibility, click \`Open Settings\`, enable STFU, then refresh. macOS may also ask for browser Automation permission.

Signing status:
- This build is unsigned/ad-hoc signed, so Gatekeeper may require Control-click > Open.
- For broad distribution, rebuild with Developer ID signing and notarization.

Checksums:
- \`STFU-$VERSION.dmg\`: \`$DMG_SHA\`
- \`STFU-$VERSION.pkg\`: \`$PKG_SHA\`
NOTES

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" "$PKG_PATH" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --target main --title "STFU $VERSION" --notes-file "$NOTES_PATH"
else
  gh release create "$TAG" "$DMG_PATH" "$PKG_PATH" \
    --repo "$REPO" \
    --target main \
    --title "STFU $VERSION" \
    --notes-file "$NOTES_PATH"
fi

gh release view "$TAG" --repo "$REPO" --json url -q .url
