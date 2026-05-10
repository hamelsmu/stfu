# STFU

<img src="assets/stfu-icon.png" alt="STFU" width="180">

Find the Mac app or browser tab making sound. Close that tab, quit that app, or silence everything.

Have you ever had a stray video, song, or mystery browser tab playing from your computer and you can't find where? This app helps you find the culprit and make it STFU.

- Browser tab making noise: close only that tab.
- Normal app making noise: quit that app.
- Multiple sound sources: close them one at a time or use `STFU Everything`.

<img width="1944" height="1528" alt="image" src="https://github.com/user-attachments/assets/582d5675-040e-4481-a02e-e86ed530a11e" />

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
- `Close Tab`: close only the noisy browser tab.
- `Quit App`: asks before quitting the noisy app. Unsaved work in that app could be lost.
- `STFU Everything`: asks before closing all noisy tabs and quitting noisy apps.
- `Open Settings`: grant Accessibility when a browser needs it.
- `Refresh`: rescan current audio sources.

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
- `just` for the shortcut commands below

Common commands:

```sh
xcode-select --install
just build
just package
just verify
just install-local
```

The underlying scripts are plain shell, so this also works without `just`:

```sh
swift build -c release
scripts/package.sh
scripts/verify.sh
```

`just verify` builds package artifacts first, then verifies the generated DMG/pkg. `scripts/verify.sh` also runs unit tests and rebuilds artifacts by default; use `VERIFY_EXISTING=1` only after a fresh package step when you want to skip rerunning `scripts/package.sh`.

Set `VERSION` when you want a different artifact name:

```sh
VERSION=0.1.1 just package
```

Artifacts are written to:

- `dist/STFU-$VERSION.pkg`
- `dist/STFU-$VERSION.dmg`

To use custom app artwork:

```sh
ARTWORK_PATH=/path/to/image.webp scripts/package.sh
```

Verify local artifacts:

```sh
VERSION=0.1.0 scripts/verify.sh
VERIFY_EXISTING=1 VERSION=0.1.0 scripts/verify.sh
```

By default, signing and Gatekeeper checks are advisory so unsigned local builds can still be verified. Set `STRICT_SIGNING=1` for signed or notarized release candidates when those checks must pass.

## Publish a GitHub Release

The local release script is the authoritative path for publishing a GitHub Release. It builds, verifies, tags, pushes, and uploads the DMG/pkg with release notes:

```sh
VERSION=0.1.0 just release
```

For signed release candidates, include `STRICT_SIGNING=1` so the release check fails if Gatekeeper rejects the DMG or pkg.

If a tag already exists and you intentionally want to replace it:

```sh
FORCE=1 VERSION=0.1.0 just release
```

The GitHub Actions workflow also builds and verifies the package on macOS for pushed tags and manual runs. It uploads CI artifacts to the workflow run; it does not mutate the GitHub Release.

You need the GitHub CLI authenticated for the local release script:

```sh
gh auth login
```

For public distribution, sign and notarize the build:

```sh
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
DMG_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="notarytool-keychain-profile" \
scripts/package.sh
```
