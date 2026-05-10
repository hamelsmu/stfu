import XCTest
@testable import STFULib

final class PureBehaviorTests: XCTestCase {
    func testParseOptionsRecognizesAllNonHelpFlags() {
        let options = parseOptions([
            "--dry-run",
            "--list",
            "--all",
            "--verbose",
            "--bundle-id",
            "com.google.Chrome",
            "--doctor",
            "--request-accessibility"
        ], emitErrors: false)

        XCTAssertEqual(options?.dryRun, true)
        XCTAssertEqual(options?.list, true)
        XCTAssertEqual(options?.all, true)
        XCTAssertEqual(options?.verbose, true)
        XCTAssertEqual(options?.bundleID, "com.google.Chrome")
        XCTAssertEqual(options?.doctor, true)
        XCTAssertEqual(options?.requestAccessibility, true)
    }

    func testParseOptionsRejectsUnknownArgumentsAndMissingBundleValue() {
        XCTAssertNil(parseOptions(["--wat"], emitErrors: false))
        XCTAssertNil(parseOptions(["--bundle-id"], emitErrors: false))
    }

    func testAppleScriptStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            appleScriptString(#"Google "Chrome" \ Audio"#),
            #""Google \"Chrome\" \\ Audio""#
        )
    }

    func testTabTitlePrefersFirstAccessibilityTextPartAndDropsAudioSuffix() {
        XCTAssertEqual(
            tabTitle(from: "Example Video - Audio playing | button | Mute tab"),
            "Example Video"
        )
        XCTAssertEqual(tabTitle(from: "  Standalone title  "), "Standalone title")
        XCTAssertEqual(tabTitle(from: "  |  Speaker  "), "Speaker")
    }

    func testAudibleIndicatorTextMatchesPlayingSignalsButNotMutedState() {
        XCTAssertTrue(isAudibleIndicatorText("Audio playing"))
        XCTAssertTrue(isAudibleIndicatorText("Mute tab"))
        XCTAssertTrue(isAudibleIndicatorText("Speaker"))

        XCTAssertFalse(isAudibleIndicatorText("Unmute site"))
        XCTAssertFalse(isAudibleIndicatorText("Muted"))
        XCTAssertFalse(isAudibleIndicatorText("No media indicator"))
    }

    func testBundleFilterMatchesExactBundleAndHelperPrefixesOnly() {
        XCTAssertTrue(matchesBundleFilter(
            AudioProcess(objectID: 0, pid: 101, bundleID: "com.google.Chrome", name: "Chrome"),
            filter: "com.google.Chrome"
        ))
        XCTAssertTrue(matchesBundleFilter(
            AudioProcess(objectID: 0, pid: 102, bundleID: "com.google.Chrome.helper", name: "Helper"),
            filter: "com.google.Chrome"
        ))

        XCTAssertFalse(matchesBundleFilter(
            AudioProcess(objectID: 0, pid: 103, bundleID: "com.google.ChromeBeta", name: "Chrome Beta"),
            filter: "com.google.Chrome"
        ))
        XCTAssertFalse(matchesBundleFilter(
            AudioProcess(objectID: 0, pid: 104, bundleID: nil, name: "Unknown"),
            filter: "com.google.Chrome"
        ))
    }

    func testChromiumRelatedShortCircuitsForExactBundleAndHelperPrefix() {
        XCTAssertTrue(isChromiumRelated(
            AudioProcess(objectID: 0, pid: 201, bundleID: "com.brave.Browser", name: "Brave"),
            appBundleID: "com.brave.Browser"
        ))
        XCTAssertTrue(isChromiumRelated(
            AudioProcess(objectID: 0, pid: 202, bundleID: "com.brave.Browser.helper", name: "Brave Helper"),
            appBundleID: "com.brave.Browser"
        ))
    }

}
