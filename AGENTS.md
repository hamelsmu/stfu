# STFU Agent Notes

## Testing

- Use [TEST_PLAN.md](./TEST_PLAN.md) as the scenario test plan.
- Test browser scenarios with the `@Chrome` plugin against the user's real Chrome browser. STFU depends on macOS CoreAudio and Accessibility seeing actual Chrome windows/tabs, so do not substitute Playwright or the in-app browser for these tests.
- Test the macOS app UI with the `@Computer` / Computer Use plugin. Use it to inspect the STFU window, verify visible row labels/buttons, and click row-level actions such as `Go to Tab`, `Go to App`, `Close Tab`, `Quit App`, and `Open Settings`.
- Test the STFU menu bar item with `@Computer` while `/Applications/STFU.app` is running. Verify it uses inline confirmations and does not require a separate Accessibility identity.
- Use the near-silent local fixture in `test-fixtures/chrome-audio.html` for Chrome audio tests, and clean up test tabs/processes immediately after each scenario. Do not leave audible tones running.
- Launch `/Applications/STFU.app` for permission-sensitive GUI tests. Avoid testing the copied build payload app for Accessibility flows because macOS can treat it as a different app identity.
- If the Chrome plugin or Computer Use cannot perform a required step, report that as a blocker instead of falling back to Playwright.

## Build and Release

- Use `just build`, `just package`, `just verify`, and `just verify-existing` for local checks. `scripts/verify.sh` rebuilds artifacts by default; use `just verify-existing` only after a fresh package step.
- Use `VERSION=x.y.z just release` as the local GitHub Release path. The GitHub Actions workflow builds and uploads CI artifacts only; it does not mutate releases.
- Do not replace an existing tag unless the user explicitly wants that release replaced; then use `FORCE=1 VERSION=x.y.z just release`.
