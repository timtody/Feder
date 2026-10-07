import XCTest

/// The onboarding sheet that asks for Gemma's download (GemmaOnboarding), and the download in the record accessory.
/// `-fakeGemmaDownload` makes the simulator an iPhone that can run Gemma, without it; `-gemmaOnboardingShown NO`
/// shows the sheet even when an earlier run has stored that it was shown (the argument overrides the stored value).
final class GemmaOnboardingTests: ScribeUITestCase {
    /// Download: the sheet goes, and the accessory says how far the download is until it is done.
    @MainActor
    func testOnboardingStartsTheDownload() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "15", "-gemmaOnboardingShown", "NO"])
        let download = app.buttons["Download Gemma (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "the sheet asks once at launch")
        XCTAssertTrue(app.staticTexts["Titles and Summaries"].exists, "its title")
        XCTAssertTrue(app.buttons["Not Now"].exists)
        shot("Onboarding", app)

        download.tap()
        XCTAssertTrue(download.waitForNonExistence(timeout: 5), "the sheet closes")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading Gemma · '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the accessory shows the download")
        shot("Accessory downloading", app)
        XCTAssertTrue(line.waitForNonExistence(timeout: 25), "done: the line goes")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '· On device'")).firstMatch.exists,
                      "the language line is back")
    }

    /// Not Now: the sheet goes and does not come back at the next launch.
    @MainActor
    func testNotNowIsRemembered() throws {
        var app = launch(["-fakeGemmaDownload", "-gemmaOnboardingShown", "NO"])
        let notNow = app.buttons["Not Now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
        app.terminate()

        app = launch(["-fakeGemmaDownload"])
        sleep(3)                                            // the sheet would come a second after launch
        XCTAssertFalse(app.buttons["Download Gemma (3.6 GB)"].exists, "asked once only")
    }

    /// Without Wi-Fi the download waits, and the accessory says so.
    @MainActor
    func testAccessoryWaitsForWiFi() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeNoWiFi", "-gemmaOnboardingShown", "NO"])
        let download = app.buttons["Download Gemma (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.staticTexts["Gemma · Waiting for Wi-Fi"].waitForExistence(timeout: 5), "waiting, said so")
        shot("Accessory waiting for Wi-Fi", app)
    }
}
