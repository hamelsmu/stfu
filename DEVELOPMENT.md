# Development

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

Set `VERSION` when you want a different artifact name:

```sh
VERSION=0.1.1 just package
```

Artifacts are written to:

- `dist/STFU-$VERSION.pkg`
- `dist/STFU-$VERSION.dmg`

Verify local artifacts:

```sh
VERSION=0.1.1
hdiutil verify "dist/STFU-$VERSION.dmg"
pkgutil --payload-files "dist/STFU-$VERSION.pkg"
```

## Publish a GitHub Release

The local release script is the authoritative path for publishing a GitHub Release. It builds, verifies, tags, pushes, and uploads the DMG/pkg with release notes:

```sh
VERSION=0.1.1 just release
```

Use a version that has not been published yet. If a tag already exists and you intentionally want to replace a draft/test release:

```sh
FORCE=1 VERSION=x.y.z just release
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

Developer ID app builds are signed with hardened runtime and the Apple Events entitlement STFU needs for browser control.
