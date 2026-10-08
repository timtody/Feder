import XCTest

/// The onboarding sheet (Onboarding) and the model downloads it leads to. `-welcomeShown NO`, `-recordingNoticeShown NO`
/// and `-improvementsOnboardingShown NO` show a page even when an earlier run stored it as passed (the argument
/// overrides the stored value; ScribeUITestCase passes YES for all three by default). `-fakeGemmaDownload` makes the
/// simulator an iPhone that can run Gemma, without it; `-fakeParakeetDownload` offers Parakeet and simulates its
/// download; `-fakeNemotronDownload` pretends Nemotron isn't there and downloads it; NetworkPath's fakes set the
/// network: `-fakeNoWiFi` (cellular), `-fakeOffline`, `-fakeLowData`, and `-fakeWiFiAfter <s>` joins Wi-Fi after that
/// many seconds.
final class OnboardingTests: ScribeUITestCase {
    /// A new install: Welcome (with the download sizes; can't be swiped away), Before You Record (with the privacy
    /// policy), then Optional Improvements with a switch each for Parakeet and Gemma; the button names what it loads.
    @MainActor
    func testNewInstallPages() throws {
        let app = launch(["-welcomeShown", "NO", "-recordingNoticeShown", "NO", "-improvementsOnboardingShown", "NO",
                          "-fakeGemmaDownload", "-fakeParakeetDownload"])
        let welcome = app.staticTexts["Welcome to Feder"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 5), "Welcome first")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '21 MB'")).firstMatch.exists,
                      "it says what downloads and how much")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'We never upload'")).firstMatch.exists)
        shot("Welcome", app)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(welcome.waitForExistence(timeout: 2), "it can't be swiped away before Continue")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 5), "then the notice")
        XCTAssertTrue(app.staticTexts["Ask First"].exists)
        XCTAssertTrue(app.buttons["Privacy Policy"].exists, "the privacy policy is one tap away")
        shot("Before You Record", app)

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Optional Improvements"].waitForExistence(timeout: 5), "then the optional downloads")
        let both = app.buttons["Download (4.2 GB)"]
        XCTAssertTrue(both.exists, "both on by default")
        let parakeet = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'More Accurate Transcripts'")).firstMatch
        let gemma = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Titles and Summaries'")).firstMatch
        XCTAssertTrue(parakeet.exists && gemma.exists, "a switch each for Parakeet and Gemma")
        shot("Optional Improvements", app)
        parakeet.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()   // its switch: Parakeet off
        XCTAssertTrue(app.buttons["Download (3.6 GB)"].waitForExistence(timeout: 2), "the button follows the switches")
        app.buttons["Not Now"].tap()
        XCTAssertTrue(app.staticTexts["Optional Improvements"].waitForNonExistence(timeout: 5), "the sheet closes")
    }

    /// An existing user (Welcome passed) sees Before You Record once, and not again at the next launch.
    @MainActor
    func testExistingUserSeesTheNoticeOnce() throws {
        var app = launch(["-recordingNoticeShown", "NO"])
        let notice = app.staticTexts["Before You Record"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Welcome to Feder"].exists, "no Welcome for an existing user")
        app.buttons["Continue"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "one page: Continue closes it")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = ["-seedSamples", "-AppleLanguages", "(en)", "-welcomeShown", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 15))
        sleep(3)                                            // the sheet would come a second after launch
        XCTAssertFalse(app.staticTexts["Before You Record"].exists, "remembered once Continue was tapped")
    }

    /// Download on Optional Improvements: the sheet goes, Parakeet downloads (the accessory shows it, then Gemma's),
    /// and once there it transcribes after Stop (Settings › Transcription reads Parakeet).
    @MainActor
    func testImprovementsStartBothDownloads() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "20", "-fakeParakeetDownload",
                          "-fakeParakeetDownloadSeconds", "6", "-improvementsOnboardingShown", "NO"])
        let download = app.buttons["Download (4.2 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "the sheet asks once at launch")
        download.tap()
        XCTAssertTrue(download.waitForNonExistence(timeout: 5), "the sheet closes")
        let parakeet = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading Parakeet · '")).firstMatch
        XCTAssertTrue(parakeet.waitForExistence(timeout: 5), "the accessory shows Parakeet's download")
        shot("Accessory downloading Parakeet", app)
        let gemma = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading Gemma · '")).firstMatch
        XCTAssertTrue(gemma.waitForExistence(timeout: 15), "then Gemma's")
        app.buttons["Settings"].firstMatch.tap()
        let transcription = app.buttons["Transcription"].firstMatch
        XCTAssertTrue(transcription.waitForExistence(timeout: 5))
        XCTAssertTrue(transcription.label.contains("Parakeet"), "downloaded, it is the engine: \(transcription.label)")
    }

    /// Not Now: the sheet goes and does not come back at the next launch.
    @MainActor
    func testNotNowIsRemembered() throws {
        var app = launch(["-fakeGemmaDownload", "-improvementsOnboardingShown", "NO"])
        let notNow = app.buttons["Not Now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
        app.terminate()

        app = XCUIApplication()                            // without the default YES: the stored value counts
        app.launchArguments = ["-seedSamples", "-AppleLanguages", "(en)", "-welcomeShown", "YES",
                               "-recordingNoticeShown", "YES", "-fakeGemmaDownload"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 15))
        sleep(3)
        XCTAssertFalse(app.staticTexts["Optional Improvements"].exists, "asked once only")
    }

    /// Off Wi-Fi, Optional Improvements says the downloads start on Wi-Fi, and the accessory says Parakeet waits; when
    /// Wi-Fi comes while the app is open, it downloads.
    @MainActor
    func testImprovementsWaitForWiFi() throws {
        let app = launch(["-fakeParakeetDownload", "-fakeParakeetDownloadSeconds", "6", "-fakeNoWiFi",
                          "-fakeWiFiAfter", "12", "-improvementsOnboardingShown", "NO"])
        let download = app.buttons["Download (610 MB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The downloads start when this iPhone is on Wi-Fi."].exists)
        download.tap()
        XCTAssertTrue(app.staticTexts["Parakeet · Waiting for Wi-Fi"].waitForExistence(timeout: 5), "waiting, said so")
        shot("Accessory Parakeet waiting", app)
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading Parakeet · '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "Wi-Fi arrived: it downloads without leaving the app")
    }

    /// Nemotron's download in the accessory: the percentage, then "Preparing speaker model…" while it is loaded, then
    /// the language line again.
    @MainActor
    func testSpeakerModelDownloadInAccessory() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeNemotronDownloadSeconds", "12"])
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading speaker model · '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 8), "the accessory shows the download")
        shot("Accessory speaker model", app)
        XCTAssertTrue(app.staticTexts["Preparing speaker model…"].waitForExistence(timeout: 20), "then preparing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '· On device'")).firstMatch
                        .waitForExistence(timeout: 10), "then the language line")
    }

    /// On cellular the speaker model waits, and starts by itself when Wi-Fi arrives while the app is open (before, only
    /// the next return to the foreground checked again).
    @MainActor
    func testSpeakerModelStartsWhenWiFiArrives() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeNemotronDownloadSeconds", "8", "-fakeNoWiFi",
                          "-fakeWiFiAfter", "8"])
        XCTAssertTrue(app.staticTexts["Speaker model · Waiting for Wi-Fi"].waitForExistence(timeout: 6), "waits on cellular")
        shot("Accessory speaker model waiting", app)
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading speaker model · '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "Wi-Fi arrived: it downloads without leaving the app")
    }

    /// Offline is "Offline", not "Waiting for Wi-Fi" (and not "Download Failed"); Settings has nothing to offer.
    @MainActor
    func testSpeakerModelOffline() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeOffline"])
        XCTAssertTrue(app.staticTexts["Speaker model · Offline"].waitForExistence(timeout: 6), "offline, said so")
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Speaker Identification"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Internet Connection"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download Now'")).firstMatch.exists,
                       "no download offered offline")
        shot("Speaker Identification offline", app)
    }

    /// On cellular, Settings offers the download over cellular with its size, and it runs.
    @MainActor
    func testSpeakerModelOverCellular() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeNemotronDownloadSeconds", "6", "-fakeNoWiFi"])
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Speaker Identification"].firstMatch.tap()
        let button = app.buttons["Download Now Using Cellular (100 MB)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the cellular download names the network and the size")
        shot("Speaker Identification cellular", app)
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: 5), "it started")
        XCTAssertTrue(app.staticTexts["Model, NVIDIA Nemotron"].waitForExistence(timeout: 20), "downloaded over cellular")
    }

    /// In Low Data Mode the download asks once more.
    @MainActor
    func testSpeakerModelLowDataMode() throws {
        let app = launch(["-fakeNemotronDownload", "-fakeLowData"])
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Speaker Identification"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Paused by Low Data Mode"].waitForExistence(timeout: 5))
        app.buttons["Download Now (100 MB)"].tap()
        XCTAssertTrue(app.alerts["Low Data Mode Is On"].waitForExistence(timeout: 5), "it asks")
        shot("Low Data Mode alert", app)
        app.alerts.buttons["Wait for Wi-Fi"].tap()
        XCTAssertTrue(app.staticTexts["Paused by Low Data Mode"].waitForExistence(timeout: 5), "still waiting")
    }

    /// A new user who records before the sheet appears (it waits a second): the onboarding is not lost, it comes once
    /// the card is closed.
    @MainActor
    func testOnboardingComesAfterAnEarlyRecording() throws {
        let app = launch(["-welcomeShown", "NO", "-recordingNoticeShown", "NO", "-autoRecord", "-autoStopAfter", "4"])
        let back = app.buttons["Minimize"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the recording card is up")
        XCTAssertFalse(app.staticTexts["Welcome to Feder"].exists, "not over the recording")
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 20), "saved: the card shows the transcript")
        closeCard(app)
        XCTAssertTrue(app.staticTexts["Welcome to Feder"].waitForExistence(timeout: 5), "then the onboarding")
    }
}
