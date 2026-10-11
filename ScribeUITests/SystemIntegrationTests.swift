import XCTest

/// Feder outside its own screens: the iPhone's search (Spotlight).
final class SystemIntegrationTests: ScribeUITestCase {
    /// The transcripts are in Core Spotlight's index (SpotlightIndex), found by a word of their text, and a result opens
    /// its card. The simulator's Spotlight screen shows no app content (iOS 27), so `-openSpotlightResult` asks the index
    /// as Spotlight does and opens the first result through the same path as a tapped result (MainView.openFromOutside).
    @MainActor
    func testSpotlightFindsTranscript() throws {
        let app = launch(["-spotlightOn", "-openSpotlightResult", "workshops"])     // a word only in Budget Review's text
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].waitForExistence(timeout: 20), "the result's card opens")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        closeCard(app)
        // (Budget Review itself may be below the screen: the tests' recordings are newer.)
        XCTAssertTrue(transcribe(app).waitForExistence(timeout: 5), "back in the list, with the record accessory")
    }
}

/// Starting and stopping from outside the app: the lock screen widget's link and the recording's Live Activity.
final class RecordingFromOutsideTests: ScribeUITestCase {
    /// feder://record (the lock screen widget) starts a transcript: the card comes up recording.
    @MainActor
    func testRecordLinkStartsATranscript() throws {
        let app = launch()
        app.open(URL(string: "feder://record")!)
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10), "recording, with the large Stop")
        app.buttons["Stop"].firstMatch.tap()
    }

    /// While recording in the background, the Live Activity is in the Dynamic Island; expanded, its Stop stops the
    /// recording (StopRecordingIntent, in the app) and the transcript is saved.
    @MainActor
    func testLiveActivityStop() throws {
        let app = launch(["-autoRecord"])
        if !app.buttons["Stop"].waitForExistence(timeout: 20) { print("APP-TREE", app.debugDescription) }
        XCTAssertTrue(app.buttons["Stop"].exists, "recording")
        sleep(3)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        sleep(2)
        // The Dynamic Island at the top centre (its time's label changes every second, so it isn't looked up by its
        // text: a found element can't be resolved again a second later). A long press expands the Live Activity.
        shot("Dynamic Island", springboard)
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: springboard.frame.midX, dy: 24))
            .press(forDuration: 1.0)                         // expands it
        // The island speaks the simulator's language (German here), not the app's launch argument.
        let stop = springboard.buttons.matching(NSPredicate(format: "label IN {'Stop', 'Stoppen'}")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop in the expanded island")
        shot("Dynamic Island expanded", springboard)
        stop.tap()
        app.activate()
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 15), "stopped and saved: the transcript")
    }
}
