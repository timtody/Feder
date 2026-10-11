import XCTest

/// App Lock (AppLock, AppLockView, Settings › App Lock). The simulator has no passcode, so Face ID is faked:
/// `-fakeAuthentication success|failure|cancel,…` answers each request in turn after 0.3 s (the last answer repeats),
/// and the switch reads "Require Face ID" as on the iPhone 17. `-appLockOn` starts with App Lock on (locking
/// Immediately); every other test launches with it off (ScribeUITestCase).
final class AppLockTests: ScribeUITestCase {
    /// Off by default with the "Off: …" footer. Turning it on asks for Face ID first: a failure springs the switch back,
    /// a success leaves it on, with the Lock picker (Immediately) and the footer that says what it does. Off again at
    /// once.
    @MainActor
    func testSwitchAsksFirst() throws {
        let app = launch(["-fakeAuthentication", "failure,success"])
        let toggle = appLockSwitch(app)
        XCTAssertEqual(toggle.label, "Require Face ID")
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        XCTAssertTrue(app.staticTexts["Off: anyone using this iPhone can open Feder."].exists)
        XCTAssertFalse(app.buttons["AppLockGrace"].exists, "no Lock picker while off")
        let header = app.staticTexts["App Lock"].firstMatch
        XCTAssertTrue(header.exists, "its own section")
        XCTAssertLessThan(app.staticTexts["Vocabulary"].firstMatch.frame.minY, header.frame.minY, "after Vocabulary")
        let search = app.switches["Show in iPhone Search"].firstMatch
        XCTAssertTrue(search.exists)
        XCTAssertLessThan(toggle.frame.maxY, search.frame.minY, "before iPhone Search")
        shot("App Lock off", app)
        let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))

        knob.tap()                                         // Face ID fails
        sleep(2)
        XCTAssertEqual(toggle.value as? String, "0", "Face ID failed: the switch sprang back")
        XCTAssertFalse(app.buttons["AppLockGrace"].exists)

        knob.tap()                                         // Face ID succeeds
        XCTAssertTrue(waitFor { (toggle.value as? String) == "1" }, "on")
        let picker = app.buttons["AppLockGrace"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the Lock picker")
        XCTAssertTrue("\(picker.label) \(picker.value as? String ?? "")".contains("Immediately"),
                      "locks immediately by default: \(picker.label) \(String(describing: picker.value))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Feder asks for Face ID'")).firstMatch
                        .waitForExistence(timeout: 5), "the footer says when it asks")
        shot("App Lock on", app)
        picker.tap()
        for choice in ["Immediately", "After 1 Minute", "After 5 Minutes", "After 15 Minutes"] {
            XCTAssertTrue(app.buttons[choice].firstMatch.waitForExistence(timeout: 5), "the choice \(choice)")
        }
        shot("Lock choices", app)
        app.buttons["After 5 Minutes"].firstMatch.tap()
        XCTAssertTrue(waitFor { "\(picker.label) \(picker.value as? String ?? "")".contains("After 5 Minutes") }, "chosen")

        knob.tap()                                         // off: nothing asked
        XCTAssertTrue(waitFor { (toggle.value as? String) == "0" }, "off at once")
        XCTAssertTrue(app.staticTexts["Off: anyone using this iPhone can open Feder."].waitForExistence(timeout: 5))
    }

    /// Turned on while Show in iPhone Search is on, it asks whether to take the transcripts out of iPhone Search. Kept:
    /// the iPhone Search footer says they show there also while Feder is locked. Removed: Show in iPhone Search is off.
    @MainActor
    func testAppLockAsksAboutIPhoneSearch() throws {
        let app = launch(["-spotlightOn", "-fakeAuthentication", "success"])
        let toggle = appLockSwitch(app)
        let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        let search = app.switches["Show in iPhone Search"].firstMatch
        XCTAssertEqual(search.value as? String, "1", "iPhone Search on (-spotlightOn)")

        knob.tap()
        let alert = app.alerts["Hide Transcripts from iPhone Search?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "it asks about iPhone Search")
        shot("Hide from iPhone Search?", app)
        alert.buttons["Keep in iPhone Search"].tap()
        XCTAssertEqual(toggle.value as? String, "1", "App Lock on")
        XCTAssertEqual(search.value as? String, "1", "kept in iPhone Search")
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'also while Feder is locked'")).firstMatch
        for _ in 0..<3 where !footer.isHittable { app.swipeUp() }
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "the iPhone Search footer says it")
        shot("iPhone Search while locked", app)

        knob.tap()                                         // off, and on again
        XCTAssertTrue(waitFor { (toggle.value as? String) == "0" })
        XCTAssertFalse(footer.exists, "only while App Lock is on")
        knob.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Remove from iPhone Search"].tap()
        XCTAssertTrue(waitFor { (search.value as? String) == "0" }, "removed: Show in iPhone Search is off")
        XCTAssertEqual(toggle.value as? String, "1", "App Lock stays on")
    }

    /// With App Lock on, Feder opens locked: the lock, "Feder Is Locked" and Unlock after a cancelled Face ID, and
    /// nothing of the list in the accessibility tree. Unlock opens it.
    @MainActor
    func testLaunchIsLocked() throws {
        let app = launch(["-appLockOn", "-fakeAuthentication", "cancel,success"], waitsForList: false)
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 15), "Unlock after the cancel")
        XCTAssertTrue(app.staticTexts["Feder Is Locked"].exists)
        XCTAssertTrue(app.staticTexts["Use Face ID to see your transcripts."].exists)
        XCTAssertFalse(app.staticTexts["Project Kickoff"].exists, "no transcript behind the lock")
        XCTAssertFalse(app.buttons["Settings"].exists, "no tab bar either")
        XCTAssertFalse(transcribe(app).exists, "nor the record accessory")
        shot("Locked", app)
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 10), "unlocked: the list")
        XCTAssertFalse(app.staticTexts["Feder Is Locked"].exists)
        XCTAssertTrue(isOnScreen(transcribe(app), app), "and the record accessory")
    }

    /// Leaving Feder locks it (Immediately) over the open card; unlocked, the same card is back as it was.
    @MainActor
    func testLeavingLocksAndKeepsTheCard() throws {
        let app = launch(["-appLockOn", "-fakeAuthentication", "success,cancel,success"], waitsForList: false)
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 15), "unlocked at launch")
        open("Project Kickoff", in: app)
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 10), "locked on return (Face ID cancelled)")
        XCTAssertFalse(app.textFields["Title"].exists, "the card is behind the lock")
        XCTAssertFalse(app.buttons["Minimize"].exists)
        shot("Locked over the card", app)
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 10), "unlocked: the card")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Project Kickoff", "the same card")
        assertCard(app)
    }

    /// With a grace period (4 s here; Settings offers 1, 5 and 15 minutes), a short trip away doesn't lock; a longer
    /// one does.
    @MainActor
    func testGracePeriod() throws {
        let app = launch(["-appLockOn", "-appLockGrace", "4", "-fakeAuthentication", "success,cancel"],
                         waitsForList: false)
        let kickoff = app.staticTexts["Project Kickoff"]
        XCTAssertTrue(kickoff.waitForExistence(timeout: 15), "unlocked at launch")
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        XCTAssertTrue(kickoff.waitForExistence(timeout: 5), "back within 4 s: not locked")
        sleep(2)                                            // the prompt would have come by now
        XCTAssertFalse(app.buttons["Unlock"].exists)
        XCTAssertTrue(isOnScreen(transcribe(app), app))

        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 10), "back after 6 s: locked")
        XCTAssertFalse(kickoff.exists)
    }

    /// A recording started from outside while Feder is locked (the Lock Screen widget's link here; Control Center, the
    /// Action Button and Siri go the same way) starts at once behind the lock, whose view shows its time, level and
    /// Stop. Face ID is asked once it records; unlocked, the card is up recording.
    @MainActor
    func testRecordLinkWhileLocked() throws {
        // -fakeSilence: nothing is transcribed, so Stop saves nothing (RecordingFromOutsideTests).
        let app = launch(["-appLockOn", "-fakeAuthentication", "cancel,cancel,success", "-fakeSilence"],
                         waitsForList: false)
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 15), "locked")
        app.open(URL(string: "feder://record")!)
        let lockStop = app.buttons["LockStop"]
        XCTAssertTrue(lockStop.waitForExistence(timeout: 15), "the lock view's recording bar, with Stop")
        XCTAssertTrue(app.staticTexts["Recording"].exists, "it says Recording")
        XCTAssertFalse(app.buttons["Minimize"].exists, "the recording card is behind the lock")
        sleep(2)                                            // Face ID was asked (and cancelled) once it recorded
        XCTAssertTrue(app.buttons["Unlock"].isHittable, "Unlock stays")
        shot("Recording while locked", app)
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10), "unlocked: the card")
        XCTAssertFalse(lockStop.exists)
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "recording, with the large Stop")
        stop.tap()
        XCTAssertTrue(transcribe(app).waitForExistence(timeout: 15), "stopped")
    }

    /// While App Lock is on, the Live Activity shows no words: "Recording" stands in their place, with the time, the
    /// meter and Stop, which still stops the recording.
    @MainActor
    func testLiveActivityHidesWords() throws {
        XCUIApplication().terminate()                      // see RecordingFromOutsideTests.testLiveActivityStop
        let app = launch(["-appLockOn", "-fakeAuthentication", "success", "-autoRecord"], waitsForList: false)
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 20), "unlocked, recording")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'quick'")).firstMatch
                        .waitForExistence(timeout: 15), "words in the app")
        sleep(2)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        sleep(3)
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: springboard.frame.midX, dy: 24))
            .press(forDuration: 1.0)                       // expands the Live Activity
        let stop = springboard.buttons.matching(NSPredicate(format: "label IN {'Stop', 'Stoppen'}")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop in the expanded island")
        // The island speaks the simulator's language, not the app's launch argument.
        let recording = springboard.staticTexts.matching(NSPredicate(format: "label IN {'Recording', 'Aufnahme'}"))
        XCTAssertTrue(recording.firstMatch.exists, "Recording in place of the words")
        for word in ["quick", "transcript", "started", "provisional", "speaker", "Listening", "Zuhören"] {
            XCTAssertFalse(springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch
                            .exists, "no words: \(word)")
        }
        shot("Live Activity without words", springboard)
        stop.tap()
        app.activate()
        let delete = app.buttons["Delete Transcript"]
        XCTAssertTrue(delete.waitForExistence(timeout: 20), "stopped and saved; unlocked again")
        delete.tap()                                       // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
    }

    // MARK: Helpers

    /// Settings, scrolled to the App Lock switch.
    @MainActor
    private func appLockSwitch(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["AppLock"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the App Lock switch")
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        // The iPhone Search section under it on screen too.
        if !app.switches["Show in iPhone Search"].firstMatch.isHittable { app.swipeUp() }
        return toggle
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return condition()
    }
}
