# STFU Test Plan

This plan assumes STFU has already been built, installed from the DMG/pkg, and is available as:

- `/Applications/STFU.app`
- `/usr/local/bin/stfu`

## Required Test Tools

- Use the `@Chrome` plugin for Chrome scenarios. These tests must run against the user's real Chrome browser because STFU depends on macOS CoreAudio and Accessibility seeing real Chrome windows and tabs.
- Use the `@Computer` / Computer Use plugin for STFU app UI inspection and row-level clicking.
- Do not use Playwright or the in-app browser as a substitute for these scenarios. If either required plugin is unavailable, record that as a blocker.
- The Chrome fixture is intentionally near-silent. Clean up Chrome test tabs and local fixture servers immediately after each scenario.
- For GUI permission tests, launch `/Applications/STFU.app`, not `.build/installer/payload/Applications/STFU.app`.

## Baseline Setup

1. Install `dist/STFU-0.1.0.dmg`.
2. Open `/Applications/STFU.app`.
3. Grant Accessibility permission to `STFU` in System Settings > Privacy & Security > Accessibility.
4. Confirm baseline health:

```sh
stfu --doctor
stfu --list
```

Expected:

- `stfu --doctor` reports CoreAudio detection works.
- Accessibility permission is granted.
- Chrome Accessibility inspection works when Chrome is running.
- The app opens without warnings, layout clipping, or unreadable text.

## Repeatable Audio Fixture

For deterministic Chrome tests, serve the included audio fixture:

```sh
cd /Users/hamel/git/stfu
python3 -m http.server 9876
```

Open an autoplaying Chrome window:

```sh
open -na "Google Chrome" --args \
  --user-data-dir=/tmp/stfu-chrome-1 \
  --no-first-run \
  --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required \
  http://127.0.0.1:9876/test-fixtures/chrome-audio.html
```

Use unique `--user-data-dir` paths for multiple independent Chrome windows when needed.

## Scenario 1: One Audio Source, Chrome

Setup:

- Open one Chrome window playing the audio fixture.
- No other apps should be producing sound.

Expected app behavior:

- STFU shows one row.
- Row name is `Google Chrome Tab 1` or equivalent tab number.
- Row detail shows `stfu Chrome audio test`.
- `Go to Tab` brings Chrome/tab forward.
- `Close Tab` closes only that tab.
- After closing, `Refresh the Suspects` shows no Chrome audio source.

CLI cross-check:

```sh
stfu --list
```

Expected after close: Chrome no longer appears as an output audio process.

## Scenario 2: Multiple Audio Sources, Chrome and Music/iTunes

Setup:

- Open one Chrome window playing the fixture.
- Start playback in Music.app, Spotify, QuickTime Player, or another non-browser app.

Expected app behavior:

- STFU shows two rows.
- Chrome row includes tab number and title.
- Non-browser row shows the app/process name.
- `Go to Tab` on Chrome focuses Chrome tab.
- `Go to App` on the non-browser app brings that app forward when possible.
- Chrome row `Close Tab` closes only the Chrome tab.
- Non-browser row `Quit App` quits/terminates only that app/process.
- `STFU Everything` closes both sources.

Important safety check:

- Closing the Chrome row must not quit Chrome.
- Closing the non-browser row must not affect the Chrome tab.

## Scenario 3: Two Audio Sources in Two Separate Chrome Windows

Setup:

```sh
open -na "Google Chrome" --args --user-data-dir=/tmp/stfu-chrome-1 --no-first-run --no-default-browser-check --autoplay-policy=no-user-gesture-required http://127.0.0.1:9876/test-fixtures/chrome-audio.html
open -na "Google Chrome" --args --user-data-dir=/tmp/stfu-chrome-2 --no-first-run --no-default-browser-check --autoplay-policy=no-user-gesture-required http://127.0.0.1:9876/test-fixtures/chrome-audio.html
```

Expected app behavior:

- STFU shows two Chrome rows.
- Each row has a tab number/title.
- `Go to Tab` focuses the correct Chrome window/tab for the selected row.
- Closing one row closes only that row’s tab/window source.
- The other Chrome audio row remains after refresh.
- `STFU Everything` closes both Chrome audio sources.

Failure conditions:

- Only one Chrome row appears while two windows are audibly playing.
- Closing one row closes both windows.
- The app focuses the wrong Chrome window.

## Scenario 4: Three Audio Sources in Three Separate Chrome Windows

Setup:

Open three independent Chrome windows/profiles, all playing the fixture:

```sh
for n in 1 2 3; do
  open -na "Google Chrome" --args \
    --user-data-dir="/tmp/stfu-chrome-$n" \
    --no-first-run \
    --no-default-browser-check \
    --autoplay-policy=no-user-gesture-required \
    http://127.0.0.1:9876/test-fixtures/chrome-audio.html
done
```

Expected app behavior:

- STFU shows three Chrome rows.
- Rows remain readable and actions remain reachable.
- Clicking `Go to Tab` on each row focuses the correct source.
- Closing a middle row leaves the other two rows valid after refresh.
- `STFU Everything` closes all three sources.

Ergonomics check:

- No horizontal scrolling required for normal-width tab titles.
- Buttons remain visible without resizing the window.
- The row selection highlight is obvious.

## Scenario 5: Three Audio Sources Across Two Chrome Windows and Spotify/GarageBand

Setup:

- Open two Chrome windows/profiles playing the fixture.
- Start playback in Spotify, Music, GarageBand, QuickTime Player, or another app.

Expected app behavior:

- STFU shows three rows:
  - Two Chrome tab rows with tab numbers/titles.
  - One non-browser app row.
- Row-level `Close Tab` and `Quit App` actions work independently for each row.
- `Go to Tab` and `Go to App` focus the selected source.
- `STFU Everything` closes/silences all three without hanging the UI.
- After `STFU Everything`, a refresh shows either no rows or only unrelated remaining system audio.

Failure conditions:

- Non-browser app is mislabeled as Chrome.
- Chrome rows collapse into one row.
- App freezes while closing multiple sources.
- Row actions become stale after closing one source.

## Visual Ergonomics Inspection

Inspect the app at these window sizes:

- Default launch size.
- Narrowest allowed width.
- Tall window with many rows.
- Dark Mode and Light Mode.

Check:

- Header uses the Pulp-style artwork as the main visual and keeps Samuel visible.
- STFU icon uses only the artwork plus large white `STFU` text, is recognizable at Dock/Finder sizes, and is not blurry.
- Black/white artwork treatment remains readable in both Dark Mode and Light Mode.
- Status text is funny but still clear.
- Error/permission states explain what to do next.
- Chrome row displays tab number and title without awkward truncation.
- Long tab titles truncate gracefully.
- Buttons fit their labels.
- `STFU Everything` only appears when more than one closable source is listed.
- Empty state is clear and not alarming.
- Table remains usable with at least 5 rows.
- Keyboard focus and double-click behavior feel predictable.

## Permission State Tests

Run with Accessibility disabled for STFU:

- App should still open.
- Chrome row should say STFU needs Accessibility access to identify the noisy tab.
- Chrome row should show `Open Settings`, not `Quit App`.
- Non-browser audio sources should still be listed.
- `stfu --doctor` should clearly report missing Accessibility permission.

Run after granting Accessibility:

- Chrome rows should include tab number/title.
- Permission warning should disappear after refresh.

## Regression Checklist

Before release:

```sh
swift build -c release
scripts/package.sh
hdiutil verify dist/STFU-0.1.0.dmg
```

Then:

- Mount DMG and confirm it contains `Install STFU.pkg`, `.VolumeIcon.icns`, and `README.txt`.
- Install package on a clean test account.
- Confirm `/Applications/STFU.app` launches.
- Confirm `/usr/local/bin/stfu --doctor` works.
- Confirm `STFU.app` is the app shown in Accessibility settings.
- Confirm the installed CLI and app both use the same permission identity.

## Cleanup

```sh
pkill -f '/tmp/stfu-chrome-' || true
rm -rf /tmp/stfu-chrome-*
```

Stop the local fixture server with `Ctrl-C`.
