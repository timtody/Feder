import XCTest

/// Gemma's download (BetterSummaries, GemmaDownload). The simulator can't run MLX and the tests must not fetch 3.6 GB:
/// `-fakeGemmaDownload` offers Gemma as if on an 8 GB iPhone and stands in for the background transfer
/// (`-fakeGemmaDownloadSeconds`, from 0 to 100 %), `-fakeNoWiFi` keeps it waiting for Wi-Fi.
/// `-improvementsOnboardingShown YES` keeps the onboarding sheet away (it has its own test).
final class GemmaDownloadTests: ScribeUITestCase {
    @MainActor
    func testDownloadInSettings() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "12", "-improvementsOnboardingShown", "YES"])
        app.buttons["Settings"].firstMatch.tap()
        let row = app.buttons["Summaries"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not downloaded"), row.label)
        row.tap()
        let download = app.buttons["Download Gemma 4 E2B (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "the download names the model and its size")
        download.tap()
        XCTAssertTrue(app.staticTexts["Downloading Gemma 4 E2B…"].waitForExistence(timeout: 5), "the progress row")
        XCTAssertTrue(app.buttons["Cancel Download"].exists, "a running download can be cancelled")
        shot("Downloading", app)
        XCTAssertTrue(app.switches["Titles and Summaries"].waitForExistence(timeout: 20), "ready: the on/off switch")
        XCTAssertFalse(app.buttons["Cancel Download"].exists)
        shot("Downloaded", app)
    }

    @MainActor
    func testWaitsForWiFiAndCancels() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeNoWiFi", "-improvementsOnboardingShown", "YES"])
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Summaries"].firstMatch.tap()
        let download = app.buttons["Download Gemma 4 E2B (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi…"].waitForExistence(timeout: 5), "no Wi-Fi: it waits")
        shot("Waiting for Wi-Fi", app)
        app.buttons["Cancel Download"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 5), "cancelled: the Download button again")
    }
}
