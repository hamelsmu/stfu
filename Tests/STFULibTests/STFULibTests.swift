import CoreAudio
@testable import STFULib
import XCTest

final class STFULibTests: XCTestCase {
    func testParseOptionsAcceptsExpectedFlags() {
        let options = parseOptions([
            "--dry-run",
            "--list",
            "--all",
            "--verbose",
            "--bundle-id",
            "com.google.Chrome"
        ], emitErrors: false)

        XCTAssertEqual(options?.dryRun, true)
        XCTAssertEqual(options?.list, true)
        XCTAssertEqual(options?.all, true)
        XCTAssertEqual(options?.verbose, true)
        XCTAssertEqual(options?.bundleID, "com.google.Chrome")
    }

    func testParseOptionsRejectsUnknownAndMissingBundleID() {
        XCTAssertNil(parseOptions(["--bogus"], emitErrors: false))
        XCTAssertNil(parseOptions(["--bundle-id"], emitErrors: false))
    }

    func testAppleScriptStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(appleScriptString(#"a "quote" and \ slash"#), #""a \"quote\" and \\ slash""#)
    }

    func testTabTitleRemovesAccessibilityNoise() {
        XCTAssertEqual(
            tabTitle(from: "Example Video - Audio playing | 1 | AXRadioButton | tab"),
            "Example Video"
        )
        XCTAssertEqual(tabTitle(from: "Example Video - Mute tab | AXButton"), "Example Video")
        XCTAssertEqual(tabTitle(from: "Example Video - playing audio | AXButton"), "Example Video")
        XCTAssertEqual(tabTitle(from: "Example Video - MUTE SITE | AXButton"), "Example Video")
    }

    func testAudibleIndicatorTextMatchesPlayingButNotMuted() {
        XCTAssertTrue(isAudibleIndicatorText("Example - Audio playing | AXTabButton"))
        XCTAssertTrue(isAudibleIndicatorText("Mute tab"))
        XCTAssertFalse(isAudibleIndicatorText("Unmute tab"))
        XCTAssertFalse(isAudibleIndicatorText("Muted"))
        XCTAssertFalse(isAudibleIndicatorText("The keynote speaker starts in 30 minutes"))
    }

    func testBundleFilterMatchesBrowserHelpers() {
        let safariWebContent = AudioProcess(
            objectID: AudioObjectID(1),
            pid: 100,
            bundleID: "com.apple.WebKit.WebContent",
            name: "Safari Web Content"
        )
        XCTAssertTrue(matchesBundleFilter(safariWebContent, filter: "com.apple.Safari"))

        let chromeHelper = AudioProcess(
            objectID: AudioObjectID(2),
            pid: 101,
            bundleID: "com.google.Chrome.helper",
            name: "Google Chrome Helper"
        )
        XCTAssertTrue(matchesBundleFilter(chromeHelper, filter: "com.google.Chrome"))
    }

    func testAutomationDeniedDetection() {
        let result = CommandResult(
            status: 1,
            output: "",
            error: "Not authorized to send Apple events to Safari. (-1743)"
        )
        XCTAssertTrue(isAutomationDenied(result))
        XCTAssertFalse(isAutomationDenied(CommandResult(status: 0, output: "1", error: "")))
    }

    func testMenuBarStatusCopyAndSymbols() {
        XCTAssertEqual(menuBarPrimaryLine(sourceCount: 0, isScanning: true, hasError: false), "Scanning...")
        XCTAssertEqual(menuBarPrimaryLine(sourceCount: 0, isScanning: false, hasError: false), "All quiet")
        XCTAssertEqual(menuBarPrimaryLine(sourceCount: 1, isScanning: false, hasError: false), "1 sound source")
        XCTAssertEqual(menuBarPrimaryLine(sourceCount: 3, isScanning: false, hasError: false), "3 sound sources")
        XCTAssertEqual(menuBarPrimaryLine(sourceCount: 1, isScanning: false, hasError: true), "Could not read sound sources")

        XCTAssertEqual(menuBarStatusSystemImage(sourceCount: 0, isScanning: true, hasError: false), "waveform")
        XCTAssertEqual(menuBarStatusSystemImage(sourceCount: 0, isScanning: false, hasError: false), "speaker.slash.fill")
        XCTAssertEqual(menuBarStatusSystemImage(sourceCount: 2, isScanning: false, hasError: false), "speaker.wave.2.fill")
        XCTAssertEqual(menuBarStatusSystemImage(sourceCount: 2, isScanning: false, hasError: true), "exclamationmark.triangle.fill")
    }

    func testMenuBarRowActionsMatchOffenderKind() {
        let app = appOffender()
        let chromium = SoundOffender(
            name: "Google Chrome Tab 2",
            detail: "Example Video",
            kind: .chromiumTab(chromeSnapshot(tabIndex: 2, title: "Example Video", label: "Example Video - Audio playing"))
        )
        let blockedAccessibility = SoundOffender(
            name: "Google Chrome",
            detail: "Needs Accessibility to identify noisy browser tabs.",
            kind: .blockedBrowser(appName: "Google Chrome", bundleID: "com.google.Chrome")
        )
        let blockedAutomation = SoundOffender(
            name: "Safari",
            detail: "Needs Automation permission to identify noisy Safari tabs.",
            kind: .blockedAutomation(BrowserAppSnapshot(name: "Safari", bundleID: "com.apple.Safari", pid: 99))
        )
        let unresolved = SoundOffender(
            name: "Google Chrome",
            detail: "Audio detected, but no matching tab was found.",
            kind: .unresolvedBrowser(BrowserAppSnapshot(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 42))
        )

        XCTAssertEqual(menuBarFocusActionTitle(for: chromium), "Go to Tab")
        XCTAssertEqual(menuBarCloseActionTitle(for: chromium), "Close Tab")
        XCTAssertEqual(menuBarFocusActionTitle(for: app), "Go to App")
        XCTAssertEqual(menuBarCloseActionTitle(for: app), "Quit App")
        XCTAssertNil(menuBarFocusActionTitle(for: blockedAccessibility))
        XCTAssertEqual(menuBarCloseActionTitle(for: blockedAccessibility), "Open Settings")
        XCTAssertNil(menuBarFocusActionTitle(for: blockedAutomation))
        XCTAssertEqual(menuBarCloseActionTitle(for: blockedAutomation), "Open Settings")
        XCTAssertEqual(menuBarFocusActionTitle(for: unresolved), "Go to App")
        XCTAssertNil(menuBarCloseActionTitle(for: unresolved))
    }

    func testMenuBarConfirmationRules() {
        let app = appOffender()
        let chromium = SoundOffender(
            name: "Google Chrome Tab 2",
            detail: "Example Video",
            kind: .chromiumTab(chromeSnapshot(tabIndex: 2, title: "Example Video", label: "Example Video - Audio playing"))
        )

        XCTAssertTrue(menuBarNeedsDestructiveConfirmation(for: app))
        XCTAssertFalse(menuBarNeedsDestructiveConfirmation(for: chromium))
        XCTAssertFalse(menuBarNeedsCloseAllConfirmation(closableCount: 0))
        XCTAssertTrue(menuBarNeedsCloseAllConfirmation(closableCount: 1))
    }

    func testCloseKeyUsesStableValueIdentity() {
        let offender = SoundOffender(
            name: "Google Chrome Tab 2",
            detail: "Example Video",
            kind: .chromiumTab(ChromiumTabSnapshot(
                appName: "Google Chrome",
                bundleID: "com.google.Chrome",
                appPID: 42,
                tabIndex: 2,
                title: "Example Video",
                label: "Example Video - Audio playing"
            ))
        )

        XCTAssertEqual(
            offenderCloseKey(for: offender),
            "chromium:com.google.Chrome:42:Example Video"
        )
    }

    func testCloseKeySurvivesChromiumTabRenumbering() {
        let before = SoundOffender(
            name: "Google Chrome Tab 2",
            detail: "Example Video",
            kind: .chromiumTab(chromeSnapshot(tabIndex: 2, title: "Example Video", label: "Example Video - Audio playing"))
        )
        let after = SoundOffender(
            name: "Google Chrome Tab 1",
            detail: "Example Video",
            kind: .chromiumTab(chromeSnapshot(tabIndex: 1, title: "Example Video", label: "Example Video - Audio playing"))
        )

        XCTAssertEqual(offenderCloseKey(for: before), offenderCloseKey(for: after))
    }

    func testCloseKeyCountsKeepDuplicateApprovedTabs() {
        let first = SoundOffender(
            name: "Google Chrome Tab 1",
            detail: "Example Video",
            kind: .chromiumTab(chromeSnapshot(tabIndex: 1, title: "Example Video", label: "Example Video - Audio playing"))
        )
        let second = SoundOffender(
            name: "Google Chrome Tab 2",
            detail: "Example Video",
            kind: .chromiumTab(chromeSnapshot(tabIndex: 2, title: "Example Video", label: "Example Video - Audio playing"))
        )

        XCTAssertEqual(offenderCloseKeyCounts(for: [first, second])[offenderCloseKey(for: first)], 2)
    }

    func testChromiumTabSelectionReturnsOneExactMatch() {
        let snapshot = chromeSnapshot(tabIndex: 2, title: "Target Video", label: "Target Video - Audio playing")
        let selected = selectChromiumTabCandidate(for: snapshot, from: [
            ChromiumTabCandidate(index: 1, title: "Other Video", label: "Other Video - Audio playing"),
            ChromiumTabCandidate(index: 2, title: "Target Video", label: "Target Video - Audio playing")
        ])

        XCTAssertEqual(selected?.index, 2)
        XCTAssertEqual(selected?.title, "Target Video")
    }

    func testChromiumTabSelectionRejectsWrongKnownIndex() {
        let snapshot = chromeSnapshot(tabIndex: 2, title: "Target Video", label: "Target Video - Audio playing")
        let selected = selectChromiumTabCandidate(for: snapshot, from: [
            ChromiumTabCandidate(index: 3, title: "Target Video", label: "Target Video - Audio playing")
        ])

        XCTAssertNil(selected)
    }

    func testChromiumTabSelectionRejectsAmbiguousMatches() {
        let snapshot = chromeSnapshot(tabIndex: nil, title: "Target Video", label: "Target Video - Audio playing")
        let selected = selectChromiumTabCandidate(for: snapshot, from: [
            ChromiumTabCandidate(index: 1, title: "Target Video", label: "Target Video - Audio playing"),
            ChromiumTabCandidate(index: 2, title: "Target Video", label: "Target Video - Audio playing")
        ])

        XCTAssertNil(selected)
    }

    func testChromiumTabSelectionRejectsSingleNonMatchingAudibleTab() {
        let snapshot = chromeSnapshot(tabIndex: 2, title: "Original Video", label: "Original Video - Audio playing")
        let selected = selectChromiumTabCandidate(for: snapshot, from: [
            ChromiumTabCandidate(index: 1, title: "Different Video", label: "Different Video - Audio playing")
        ])

        XCTAssertNil(selected)
    }

    private func chromeSnapshot(
        tabIndex: Int?,
        title: String,
        label: String
    ) -> ChromiumTabSnapshot {
        ChromiumTabSnapshot(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            appPID: 42,
            tabIndex: tabIndex,
            title: title,
            label: label
        )
    }

    private func appOffender() -> SoundOffender {
        SoundOffender(
            name: "Music",
            detail: "App audio source",
            kind: .app(AudioProcess(
                objectID: AudioObjectID(10),
                pid: 24,
                bundleID: "com.apple.Music",
                name: "Music"
            ))
        )
    }
}
