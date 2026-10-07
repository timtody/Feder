import XCTest

/// The onboarding sheet (Onboarding): Nemotron's page (it downloads by itself; the page shows how far) and Gemma's
/// (Download / Not Now), and both downloads in the record accessory. `-fakeNemotronDownload` pretends Nemotron isn't
/// there yet and downloads it at launch; `-fakeGemmaDownload` makes the simulator an iPhone that can run Gemma, without
/// it. `-nemotronOnboardingShown NO` / `-gemmaOnboardingShown NO` show a page even when an earlier run stored that it
/// was shown (the argument overrides the stored value). Without `-fakeNemotronDownload` the simulator has no Nemotron
/// download, so the Gemma tests get Gemma's page alone.
final class OnboardingTests: ScribeUITestCase {
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

    /// A new install on an 8 GB iPhone: Nemotron's page with its download running, Continue, then Gemma's page.
    @MainActor
    func testBothPages() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeNemotronDownloadSeconds", "20", "-fakeGemmaDownload",
                          "-nemotronOnboardingShown", "NO", "-gemmaOnboardingShown", "NO"])
        XCTAssertTrue(app.staticTexts["Know Who Said What"].waitForExistence(timeout: 5), "Nemotron's page first")
        let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading '")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "its download, live")
        shot("Onboarding speakers", app)
        app.buttons["Continue"].tap()
        let download = app.buttons["Download Gemma (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "then Gemma's page")
        XCTAssertFalse(app.staticTexts["Your Earlier Transcripts Too"].exists, "no row about earlier transcripts")
        shot("Onboarding summaries", app)
        app.buttons["Not Now"].tap()
        XCTAssertTrue(download.waitForNonExistence(timeout: 5), "the sheet closes")
    }

    /// Nemotron's download in the accessory: the percentage, then "Preparing speaker model…" while it is loaded, then
    /// the language line again. Its page alone on a smaller iPhone (no Gemma): Continue ends the sheet.
    @MainActor
    func testSpeakerModelDownloadInAccessory() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeNemotronDownloadSeconds", "12", "-nemotronOnboardingShown", "NO"])
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(next.waitForNonExistence(timeout: 5), "one page only: Continue closes it")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading speaker model · '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the accessory shows the download")
        shot("Accessory speaker model", app)
        XCTAssertTrue(app.staticTexts["Preparing speaker model…"].waitForExistence(timeout: 20), "then preparing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '· On device'")).firstMatch
                        .waitForExistence(timeout: 10), "then the language line")
    }

    /// No Wi-Fi: Nemotron's page and the accessory say it waits.
    @MainActor
    func testSpeakerModelWaitsForWiFi() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeNoWiFi", "-nemotronOnboardingShown", "NO"])
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].waitForExistence(timeout: 5), "the page says it waits")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Speaker model · Waiting for Wi-Fi"].waitForExistence(timeout: 5), "so does the accessory")
        shot("Accessory speaker model waiting", app)
    }
}
