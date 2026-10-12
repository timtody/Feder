import XCTest

/// Shared setup of Feder's UI tests. Every test launches the app (Debug, simulator fakes) with `-seedSamples`, which
/// replaces the sample transcripts in the app's store: "Project Kickoff" (newest; Anna Schmidt and Jonas Weber, two
/// turns each, so its name rows are SpeakerHeader.0-3) and "Budget Review" (Lena Vogel and Anna Schmidt).
/// Simulator only: they write to the app's own store, so on an iPhone (real transcripts and people) every test is skipped
/// (and the app ignores `-seedSamples` there).
/// Screenshots are kept as attachments of the result bundle (`shot`).
class ScribeUITestCase: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Feder's UI tests write to the app's own store: run them on a simulator, never on an iPhone with real data")
        #endif
    }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // English unless a test asks for another language: the queries match the English labels, and the app follows
        // the simulator's language otherwise (Localizable.xcstrings has German).
        let language = arguments.contains("-AppleLanguages") ? [] : ["-AppleLanguages", "(en)"]
        // The onboarding's pages count as passed unless a test asks for them (a fresh simulator has no transcripts, so
        // the app would take it for a new install and cover the list with the sheet).
        let onboarding = ["-welcomeShown", "-recordingNoticeShown", "-voiceProfilesOnboardingShown", "-spotlightOnboardingShown", "-improvementsOnboardingShown"]
            .filter { !arguments.contains($0) }.flatMap { [$0, "YES"] }
        // Recognize People by Voice is off on a new install; the tests run with it on (the seeded people get voice
        // profiles), unless a test asks for a new install's state (`-resetVoiceRecognition`).
        let voices = arguments.contains("-resetVoiceRecognition") ? [] : ["-voiceRecognitionOn"]
        app.launchArguments = ["-seedSamples"] + language + onboarding + voices + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 15), "the seeded transcripts are listed")
        return app
    }

    /// Opens a transcript from the list (or the search results): the transcript card comes up (no push) and its first
    /// name row is there.
    @MainActor
    func open(_ title: String, in app: XCUIApplication) {
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].waitForExistence(timeout: 10), "\(title) opened")
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, title, "the card shows \(title)")
    }

    /// The transcript card is up: the back button ("Minimize") at the top left, the transcript's actions in the bottom
    /// toolbar, no navigation bar with a Back button, and the tab bar and the record accessory covered.
    @MainActor
    func assertCard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["Minimize"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the card's back button", file: file, line: line)
        XCTAssertLessThan(back.frame.minY, 100, "the back button at the top: \(back.frame)", file: file, line: line)
        XCTAssertLessThan(back.frame.minX, 40, "at the leading edge: \(back.frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(back.frame.width, 40, "a 44 pt glass circle: \(back.frame)", file: file, line: line)
        // Delete: in the bar in every mode (opened from a search result, Share is in the More menu).
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 10), "the bottom toolbar",
                      file: file, line: line)
        // The navigation bar of the screen the card covers (Settings › People › person) stays in the tree: only a
        // reachable one counts.
        let barButtons = app.navigationBars.buttons.allElementsBoundByIndex.filter { $0.isHittable }.map(\.label)
        XCTAssertEqual(barButtons, [], "no top bar, no Back", file: file, line: line)
        XCTAssertFalse(isOnScreen(transcribe(app), app), "the record accessory is covered", file: file, line: line)
        XCTAssertFalse(isOnScreen(app.buttons["Settings"].firstMatch, app), "the tab bar is covered",
                       file: file, line: line)
    }

    /// The back button closes the card; returns once it is gone.
    @MainActor
    func closeCard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["Minimize"].tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "the card closed", file: file, line: line)
    }

    /// Swipes the card away to the right: a pan from the left screen edge (the back gesture) across most of the width.
    @MainActor
    func swipeCardRight(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 320, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Taps Transcribe and answers the microphone permission alert, should the simulator ask.
    @MainActor
    func startRecording(_ app: XCUIApplication) {
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            for label in ["Allow", "Erlauben", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        transcribe(app).tap()
        app.tap()                                                           // lets the monitor answer a permission alert
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 10), "the card's live view")
    }

    /// The record accessory without a recording ("● Transcribe").
    @MainActor
    func transcribe(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Transcribe"].firstMatch
    }

    /// There and tappable (covered by the card: absent, or not hittable).
    @MainActor
    func isOnScreen(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        element.exists && element.isHittable
    }

    /// The rename sheet's name field.
    @MainActor
    func nameField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["SpeakerNameField"]
    }

    /// A fresh simulator's keyboard first covers itself with a swipe-typing tip.
    @MainActor
    func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.keyboards.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
    }

    /// A screenshot kept in the result bundle.
    @MainActor
    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Text kept in the result bundle (measurements, the accessibility tree while writing a test).
    func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// How much of `rect` (points) stands out sharply from its background: the share of pixels whose brightness differs
    /// from the region's median by more than 0.7 (crisp black text on white, or white on black, differs by about 1;
    /// text under the system's soft scroll edge is faded and blurred well below that).
    @MainActor
    func crispShare(of rect: CGRect, in app: XCUIApplication) -> Double {
        guard let image = app.screenshot().image.cgImage else { return 0 }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                            height: rect.height * scale).integral
        guard let cropped = image.cropping(to: pixels) else { return 0 }
        let width = cropped.width, height = cropped.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        let median = Int(gray.sorted()[gray.count / 2])
        let crisp = gray.filter { abs(Int($0) - median) > 178 }.count
        return Double(crisp) / Double(max(gray.count, 1))
    }
}
