import XCTest
import notify

/// Shared setup of Feder's UI tests. Every test launches the app (Debug, simulator fakes) with `-seedSamples`, which
/// replaces the sample transcripts in the app's store: "Project Kickoff" (newest; Anna Schmidt and Jonas Weber, two
/// turns each, so its name rows are SpeakerHeader.0-3) and "Budget Review" (Lena Vogel and Anna Schmidt).
/// Simulator only: they write to the app's own store, so on an iPhone (real transcripts and people) every test is skipped
/// (and the app ignores `-seedSamples` there).
/// Screenshots are kept as attachments of the result bundle (`shot`).
class ScribeUITestCase: XCTestCase {
    /// The seeded Budget Review's link (PreviewData.budgetID), as Reminders and the system open it: ActionItemsTests
    /// reads it back from Reminders, TranscriptListTests opens it while another card is up.
    static let budgetLink = "feder://transcript/5C0FFEE0-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Feder's UI tests write to the app's own store: run them on a simulator, never on an iPhone with real data")
        #endif
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// When the last `launch` began: the seeded transcripts are dated after it (see dayWords).
    private(set) var launchedAt = Date.now

    /// `waitsForList: false` for a launch that is locked (App Lock, `-appLockOn`): the list is behind the lock and hidden
    /// from the accessibility tree.
    @MainActor
    func launch(_ arguments: [String] = [], waitsForList: Bool = true) -> XCUIApplication {
        launchedAt = .now
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

    /// Taps a row's only tag chip (a row of the Transcripts list or a person's page, the two that use it). VoiceOver
    /// reads the meta line as one element (its chips are actions), so the chip is reached by position: the last one
    /// shown ends the line (`MetaLineLayout` is as wide as what it shows).
    @MainActor
    func tapTag(_ tag: String, inRow title: String, _ app: XCUIApplication) {
        let meta = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "Tag: \(tag)")).allElementsBoundByIndex
            .first { abs($0.frame.minY - app.staticTexts[title].frame.maxY) < 12 }
        guard let meta else { return XCTFail("\(title)'s meta line with the tag \(tag)") }
        meta.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: meta.frame.width - 12, dy: meta.frame.height / 2)).tap()
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
    func crispShare(of rect: CGRect, in app: XCUIApplication,
                    file: StaticString = #filePath, line: UInt = #line) -> Double {
        // A failed read must not pass for "nothing crisp" (callers assert a share near 0); reported at the caller.
        guard let pixels = grayPixels(of: rect, in: app) else {
            XCTFail("no pixels in \(rect)", file: file, line: line)
            return 1
        }
        let gray = pixels.values
        let median = Int(gray.sorted()[gray.count / 2])
        let crisp = gray.filter { abs(Int($0) - median) > 178 }.count
        return Double(crisp) / Double(max(gray.count, 1))
    }

    /// How strongly a horizontal line crosses `rect` (points): per pixel row, the share of its columns whose brightness
    /// differs by more than 10/255 from the same column 2 pt higher; the largest share. A separator across the rect gives
    /// about 1. Comparing each column with itself keeps vertical edges (an inset grouped card's side) and plain
    /// backgrounds at about 0. XCUITest can't see separators, so the pixels have to tell.
    @MainActor
    func lineShare(in rect: CGRect, _ app: XCUIApplication,
                   file: StaticString = #filePath, line: UInt = #line) -> Double {
        // A failed read must not pass for "no line" (the check left of the text asserts a share near 0); reported at
        // the caller.
        guard let pixels = grayPixels(of: rect, lift: 2, in: app), pixels.height > pixels.lift else {
            XCTFail("no pixels in \(rect)", file: file, line: line)
            return 0
        }
        let gray = pixels.values, width = pixels.width, height = pixels.height, lift = pixels.lift
        var best = 0.0
        for y in lift..<height {
            let differing = (0..<width).count(where: { x in
                abs(Int(gray[y * width + x]) - Int(gray[(y - lift) * width + x])) > 10
            })
            best = max(best, Double(differing) / Double(width))
        }
        return best
    }

    /// Brightness 0-255 per pixel, row by row from the top; the first `lift` rows lie above the rect asked for.
    private struct GrayPixels { var values: [UInt8]; var width: Int; var height: Int; var lift: Int }

    /// A screenshot's pixels in `rect` (points) as brightness, with `lift` points more above it (lineShare compares
    /// each row with the one 2 pt higher); nil for a rect off the screenshot, a screenshot without a CGImage or a
    /// context that can't be made. The context draws into the array inside `withUnsafeMutableBytes`: the pointer
    /// `&gray` gives CGContext's init is valid only during that call, and the context wrote through it later, in
    /// `draw` (crispShare and lineShare each did so until FED-84).
    @MainActor
    private func grayPixels(of rect: CGRect, lift: CGFloat = 0, in app: XCUIApplication) -> GrayPixels? {
        guard let image = app.screenshot().image.cgImage else { return nil }
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let liftPixels = Int((lift * scale).rounded())
        let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale - CGFloat(liftPixels), width: rect.width * scale,
                          height: rect.height * scale + CGFloat(liftPixels)).integral
        guard let cropped = image.cropping(to: crop), cropped.width > 0, cropped.height > 0 else { return nil }
        let width = cropped.width, height = cropped.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? GrayPixels(values: gray, width: width, height: height, lift: liftPixels) : nil
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
        let left = lineShare(in: CGRect(x: 1, y: y - 2, width: textX - 4, height: 4), app, file: file, line: line)
        let right = lineShare(in: CGRect(x: textX + 2, y: y - 2, width: 120, height: 4), app, file: file, line: line)
        note("Separator under \(title)",
             "row \(row.frame), text at x \(textX): line share left of the text \(left), right of it \(right)")
        XCTAssertLessThan(left, 0.2, "\(title): no separator left of the text (x 1-\(textX - 3))", file: file, line: line)
        XCTAssertGreaterThan(right, 0.8, "\(title): the separator from the text on", file: file, line: line)
    }

    /// The day words a line for `since` may show when it was drawn between `drawnAfter` (default `since`) and `until`:
    /// the app words a date when it draws its line (`relativeDayText`) and doesn't redraw it at midnight, so a run
    /// across midnight may show either for the same date. "Today" only when the line may have been drawn on `since`'s
    /// day, "Yesterday" only when it may have been drawn after midnight; on any other day just "Today", as strict as
    /// before (FED-51).
    func dayWords(since: Date, drawnAfter: Date? = nil, until: Date = .now) -> [String] {
        let drawn = max(since, drawnAfter ?? since), read = max(drawn, until)
        return (Calendar.current.isDate(since, inSameDayAs: drawn) ? ["Today"] : [])
            + (Calendar.current.isDate(since, inSameDayAs: read) ? [] : ["Yesterday"])
    }

    /// A query predicate for a date line of something dated after `since`, read by `until`: `format` (with one %@) for
    /// "Today at " and, across midnight, "Yesterday at " (dayWords), each after `prefix`.
    func dayLine(since: Date, until: Date, _ format: String, prefix: String = "") -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: dayWords(since: since, until: until).map {
            NSPredicate(format: format, prefix + $0 + " at ")
        })
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

    /// The element's keyboard focus; nil when it can't be read (the element is gone). "Focus lost" checks that must not
    /// pass for a vanished element compare this to `false`; `hasFocus` folds nil into false.
    @MainActor
    var keyboardFocus: Bool? { value(forKey: "hasKeyboardFocus") as? Bool }

    @MainActor
    var hasFocus: Bool { keyboardFocus ?? false }

    /// Has the keyboard focus within `timeout` (`hasKeyboardFocus`, polled as `appears`). `typeText` checks it only
    /// once, at once.
    @MainActor
    func getsFocus(timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { $0.keyboardFocus == true }
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
