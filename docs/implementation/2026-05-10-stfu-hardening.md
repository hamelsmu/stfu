# 2026-05-10 STFU Hardening Implementation

This branch is rebased on `origin/main` and organizes the work into reviewable phases.

## Commits

- `Extract app logic into STFU library`: moves the former single-file executable into `STFULib` modules and leaves `Sources/stfu/main.swift` as a small launcher.
- `Add focused pure behavior tests`: adds a SwiftPM test target covering option parsing, AppleScript escaping, tab-title cleanup, audio indicator matching, and bundle-prefix matching.
- `Harden offender actions and UI scans`: keeps scan results as Sendable snapshots, resolves browser/AppKit handles at action time, moves rescans off the main UI path, and refuses Chromium tab closes when Accessibility selection fails.
- `Improve release checks and PR context`: runs unit tests from `scripts/verify.sh`, makes artifact verification output clearer, fixes noisy `xattr` cleanup, removes the hardcoded local test path, and documents this implementation.

## Validation

- `swift test`
- `swift build -c release`
- `scripts/verify.sh`
