# STFU

<img src="assets/stfu-icon.png" alt="STFU" width="180">

Have you ever had a stray video, song, or mystery browser tab playing from your computer and you can't find where? STFU helps you find the culprit and make it STFU.

- Browser tab making noise: close only that tab.
- Normal app making noise: quit that app.
- Multiple offenders: close them one at a time or use `STFU Everything`.

![STFU app showing multiple sound offenders](assets/screenshots/app-multiple-sources.png)

## Install

Download the latest `STFU-*.dmg` from [GitHub Releases](https://github.com/hamelsmu/stfu/releases/latest), open it, and run `Install STFU.pkg`.

The installer adds:

- `/Applications/STFU.app`
- `/usr/local/bin/stfu`

Current release builds are unsigned unless the release notes say otherwise. If macOS blocks the installer, Control-click `Install STFU.pkg`, choose `Open`, and confirm you want to run it.

## Supported Sources

STFU closes individual noisy tabs for:

- Safari
- Google Chrome, Chrome Canary, Microsoft Edge, Brave, Chromium, and Arc

Other audio producers are shown as apps and can be quit from STFU.

## Permissions

Open `STFU.app`. If a browser row says it needs Accessibility, click `Open Settings`, then enable STFU in:

`System Settings > Privacy & Security > Accessibility`

macOS requires that permission so STFU can inspect browser tab strips and close only the noisy tab.

If STFU already appears enabled but Chrome still asks, toggle STFU off and on once. That can happen after replacing a local unsigned build.

macOS may also ask whether STFU can control Safari, Chrome, or another browser. Allow it; that Automation permission is how STFU focuses or closes the offending tab.

You can check the local setup from Terminal:

```sh
stfu --doctor
stfu --request-accessibility
```

## Use

In the app:

- `Go to Tab` / `Go to App`: jump to the noisy source.
- `Close Tab` / `Quit App`: silence that source.
- `Open Settings`: grant Accessibility when Chrome needs it.
- `Refresh the Suspects`: rescan current audio sources.

From Terminal:

```sh
stfu --list
stfu --dry-run
stfu
stfu --all
stfu --doctor
stfu --request-accessibility
```

## Build Locally

Requirements:

- macOS 14+
- Xcode command line tools
- Swift 6.0+

Build the CLI:

```sh
xcode-select --install
swift build -c release
```

Build the installer package and DMG:

```sh
scripts/package.sh
```

Artifacts are written to:

- `dist/STFU-0.1.0.pkg`
- `dist/STFU-0.1.0.dmg`

The default artwork is `assets/pulpfiction_new.webp`. To use different artwork:

```sh
ARTWORK_PATH=/path/to/image.webp scripts/package.sh
```

Use artwork you have rights to distribute.

Use `VERSION` to build a different release version:

```sh
VERSION=0.1.1 scripts/package.sh
```

Verify local artifacts:

```sh
hdiutil verify dist/STFU-0.1.0.dmg
pkgutil --payload-files dist/STFU-0.1.0.pkg
```

## Publish a GitHub Release

This repo includes a GitHub Actions release workflow. After pushing the repo to GitHub, create a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds the DMG on macOS and uploads `STFU-0.1.0.dmg` plus `STFU-0.1.0.pkg` to the GitHub Release.

Manual release from a local machine also works:

```sh
scripts/package.sh
gh release create v0.1.0 dist/STFU-0.1.0.dmg dist/STFU-0.1.0.pkg \
  --title "STFU 0.1.0" \
  --notes "Initial STFU release."
```

For public distribution, sign and notarize the build:

```sh
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
DMG_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="notarytool-keychain-profile" \
scripts/package.sh
```
