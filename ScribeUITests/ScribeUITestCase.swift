import XCTest
import notify

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

    /// `waitsForList: false` for a launch that is locked (App Lock, `-appLockOn`): the list is behind the lock and hidden
    /// from the accessibility tree.
    @MainActor
    func launch(_ arguments: [String] = [], waitsForList: Bool = true) -> XCUIApplication {
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
        // App Lock is off unless a test turns it on (`-appLockOn`): a test that turned it on in Settings would otherwise
        // leave every later one locked.
        let lock = arguments.contains("-appLockOn") ? [] : ["-resetAppLock"]
        // On Wi-Fi unless a test picks another network (NetworkPath's fakes): the simulator shares the Mac's network, and
        // a Mac on a Personal Hotspot or in Low Data Mode kept the fake downloads waiting for Wi-Fi.
        let network = ["-fakeNoWiFi", "-fakeOffline", "-fakeLowData"].contains(where: arguments.contains) ? [] : ["-fakeWiFi"]
        app.launchArguments = ["-seedSamples"] + language + onboarding + voices + lock + network + arguments
        app.launch()
        if waitsForList {
            XCTAssertTrue(app.staticTexts["Project Kickoff"].appears(timeout: 15), "the seeded transcripts are listed")
        }
        return app
    }

    /// Opens a transcript from the list (or the search results): the transcript card comes up (no push) and its first
    /// name row is there.
    @MainActor
    func open(_ title: String, in app: XCUIApplication) {
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].appears(timeout: 10), "\(title) opened")
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, title, "the card shows \(title)")
    }

    /// The transcript card is up: the back button ("Minimize") at the top left, the transcript's actions in the bottom
    /// toolbar, no navigation bar with a Back button, and the tab bar and the record accessory covered.
    @MainActor
    func assertCard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["Minimize"]
        XCTAssertTrue(back.appears(timeout: 10), "the card's back button", file: file, line: line)
        XCTAssertLessThan(back.frame.minY, 100, "the back button at the top: \(back.frame)", file: file, line: line)
        XCTAssertLessThan(back.frame.minX, 40, "at the leading edge: \(back.frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(back.frame.width, 40, "a 44 pt glass circle: \(back.frame)", file: file, line: line)
        // Delete: in the bar in every mode (opened from a search result, Share is in the More menu).
        XCTAssertTrue(app.buttons["Delete Transcript"].appears(timeout: 10), "the bottom toolbar",
                      file: file, line: line)
        // The navigation bar of the screen the card covers (Settings › People › person) stays in the tree: only a
        // reachable one counts.
        let barButtons = app.navigationBars.buttons.allElementsBoundByIndex.filter { $0.isHittable }.map(\.label)
        XCTAssertEqual(barButtons, [], "no top bar, no Back", file: file, line: line)
        XCTAssertFalse(isOnScreen(transcribe(app), app), "the record accessory is covered", file: file, line: line)
        XCTAssertFalse(isOnScreen(app.buttons["Settings"].firstMatch, app), "the tab bar is covered",
                       file: file, line: line)
    }

    /// Add Tag or Edit Text: in the card's More menu since Find took a place in its bar (FED-79). Opens the menu and
    /// taps the item; with `waitsUntilEnabled`, closes and reopens the menu until the item can be tapped (Edit Text
    /// waits for the steps after Stop).
    @MainActor
    func tapMenuItem(_ label: String, in app: XCUIApplication, waitsUntilEnabled: Bool = false, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date.now + timeout
        while true {
            app.buttons["More"].firstMatch.tap()
            let item = app.buttons[label].firstMatch
            XCTAssertTrue(item.appears(timeout: 5), "\(label) in the More menu", file: file, line: line)
            if item.isEnabled || !waitsUntilEnabled || Date.now > deadline {
                item.tap()
                return
            }
            // Closes the menu: a tap on the card's empty top right.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
            RunLoop.current.run(until: .now + 1)
        }
    }

    /// The back button closes the card; returns once it is gone.
    @MainActor
    func closeCard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // The button's middle, as a finger taps it: `tap()` aims at a point XCUITest picks from the accessibility tree,
        // which missed the button on a card scrolled to its end with the title under the button (Budget Review with its
        // action items); a tap on the middle closed it there every time.
        app.buttons["Minimize"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card closed", file: file, line: line)
    }

    /// Swipes the card away to the right: a pan from the left screen edge (the back gesture) across most of the width.
    @MainActor
    func swipeCardRight(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 320, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// The transcript card's Delete, confirmed: test recordings don't pile up in the simulator's store.
    @MainActor
    func deleteOpenTranscript(_ app: XCUIApplication) {
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card closes")
    }

    /// Polls `condition` every 0.2 s until it holds or `timeout` has passed (once per class until October 2026, the
    /// same in each). XCUITest's own expectations poll about once a second.
    @MainActor
    func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return condition()
    }

    @MainActor
    func waitFor(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        waitFor(timeout: timeout, condition)
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
        XCTAssertTrue(app.staticTexts["Recording"].appears(timeout: 10), "the card's live view")
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
        if tip.appears(timeout: 1) { tip.tap() }
    }

    /// Shakes the simulated iPhone as Device › Shake does: UIKit registers for this Darwin notification in the simulator
    /// and takes the iPhone's path from it (`motionEnded`, the key window's first responder's UndoManager, iOS's "Undo …"
    /// alert). Returns that alert when it comes within `timeout`, nil otherwise. (A shake did reach the iOS 27
    /// simulator all along: with nothing first responder it found no UndoManager, as on the iPhone, FED-7.)
    /// On a simulator that never showed iOS's one-time editing-gestures tutorial (a new one), the alert's first Undo
    /// never reached the app's UndoManager, so the first shake test there failed ("undone: …"); the simulator needs
    /// `KeyboardDidShowProductivityTutorial` set once (README › UI tests, `build/qa/uitests.sh`).
    @MainActor
    func shake(_ app: XCUIApplication, timeout: TimeInterval = 3) -> XCUIElement? {
        notify_post("com.apple.UIKit.SimulatorShake")
        let alert = app.alerts.firstMatch
        return alert.appears(timeout: timeout) ? alert : nil
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

    /// The next `weekday` (Sunday = 1) strictly after `day`, at its start (DueDate's rule for "by Friday": said on a
    /// Friday, the one a week later).
    func next(_ weekday: Int, after day: Date) -> Date {
        let calendar = Calendar.current
        var ahead = (weekday - calendar.component(.weekday, from: day) + 7) % 7
        if ahead == 0 { ahead = 7 }
        return calendar.date(byAdding: .day, value: ahead, to: calendar.startOfDay(for: day))!
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

    /// How strongly a horizontal line crosses `rect` (points): per pixel row, the share of its columns whose brightness
    /// differs by more than 10/255 from the same column 2 pt higher; the largest share. A separator across the rect gives
    /// about 1. Comparing each column with itself keeps vertical edges (an inset grouped card's side) and plain
    /// backgrounds at about 0. XCUITest can't see separators, so the pixels have to tell.
    @MainActor
    func lineShare(in rect: CGRect, _ app: XCUIApplication) -> Double {
        guard let image = app.screenshot().image.cgImage else { return 0 }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let lift = Int((2 * scale).rounded())
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale - CGFloat(lift), width: rect.width * scale,
                            height: rect.height * scale + CGFloat(lift)).integral
        guard let cropped = image.cropping(to: pixels) else { return 0 }
        let width = cropped.width, height = cropped.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard width > 0, height > lift,
              let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        var best = 0.0
        for y in lift..<height {
            let differing = (0..<width).count(where: { x in
                abs(Int(gray[y * width + x]) - Int(gray[(y - lift) * width + x])) > 10
            })
            best = max(best, Double(differing) / Double(width))
        }
        return best
    }

    /// The separator under the row titled `title` starts at the row's text, as in Voice Memos, Settings and Contacts:
    /// nothing between the screen's edge and the title's leading edge, the line from there on. (FED-74: the person page's
    /// separators started off-screen and crossed its inset grouped card's edge; the Transcripts list's started at the
    /// screen's edge.)
    @MainActor
    func assertSeparatorStartsAtText(under title: String, _ app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let row = app.cells.containing(.staticText, identifier: title).firstMatch
        let textX = app.staticTexts[title].firstMatch.frame.minX
        let y = row.frame.maxY
        let left = lineShare(in: CGRect(x: 1, y: y - 2, width: textX - 4, height: 4), app)
        let right = lineShare(in: CGRect(x: textX + 2, y: y - 2, width: 120, height: 4), app)
        note("Separator under \(title)",
             "row \(row.frame), text at x \(textX): line share left of the text \(left), right of it \(right)")
        XCTAssertLessThan(left, 0.2, "\(title): no separator left of the text (x 1-\(textX - 3))", file: file, line: line)
        XCTAssertGreaterThan(right, 0.8, "\(title): the separator from the text on", file: file, line: line)
    }
}

extension XCUIElement {
    /// `waitForExistence(timeout:)`, but at once when the element is there already, then every 0.2 s: XCUITest's own
    /// waits look first after about a second, also for an element already on screen, which was most of the suite's
    /// time waiting (1,179 waits, 28 of 81 minutes summed, in October 2026's parallel run).
    /// When it had to wait, a quarter of a second more: what just appeared is usually still coming in (a menu, a
    /// swipe pill, the next of two pills), and a tap or a check at once raced it (October 2026's first full run with
    /// these waits: three tests).
    @MainActor
    func appears(timeout: TimeInterval) -> Bool {
        if exists { return true }
        guard poll(timeout: timeout, { $0.exists }) else { return false }
        RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        return true
    }

    /// `waitForNonExistence(timeout:)`, polled the same way.
    @MainActor
    func disappears(timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { !$0.exists }
    }

    @MainActor
    private func poll(timeout: TimeInterval, _ condition: (XCUIElement) -> Bool) -> Bool {
        if condition(self) { return true }
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
            if condition(self) { return true }
        }
        return false
    }
}
