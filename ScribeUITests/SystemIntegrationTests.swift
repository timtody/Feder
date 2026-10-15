import XCTest

/// Feder outside its own screens: the iPhone's search (Spotlight).
final class SystemIntegrationTests: ScribeUITestCase {
    /// The transcripts are in Core Spotlight's index (SpotlightIndex), found by a word of their text, and a result opens
    /// its card. The simulator's Spotlight screen shows no app content (iOS 27), so `-openSpotlightResult` asks the index
    /// as Spotlight does and opens the first result through the same path as a tapped result (MainView.openFromOutside).
    @MainActor
    func testSpotlightFindsTranscript() throws {
        let app = launch(["-spotlightOn", "-openSpotlightResult", "workshops"])     // a word only in Budget Review's text
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].appears(timeout: 20), "the result's card opens")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        closeCard(app)
        // (Budget Review itself may be below the screen: the tests' recordings are newer.)
        XCTAssertTrue(transcribe(app).appears(timeout: 5), "back in the list, with the record accessory")
    }
}

/// Starting and stopping from outside the app: the lock screen widget's link and the recording's Live Activity.
final class RecordingFromOutsideTests: ScribeUITestCase {
    /// feder://record (the lock screen widget) starts a transcript: the card comes up recording.
    @MainActor
    func testRecordLinkStartsATranscript() throws {
        // -fakeSilence: nothing is transcribed, so Stop saves nothing (each saved test recording is newer than the
        // samples and pushes Budget Review further down the list other tests open it from).
        let app = launch(["-fakeSilence"])
        app.open(URL(string: "feder://record")!)
        XCTAssertTrue(app.buttons["Stop"].appears(timeout: 10), "recording, with the large Stop")
        app.buttons["Stop"].firstMatch.tap()
    }

    /// While recording in the background, the Live Activity is in the Dynamic Island; expanded, its Stop stops the
    /// recording (StopRecordingIntent, in the app): back in the app the accessory says Transcribe again.
    @MainActor
    func testLiveActivityStop() throws {
        // An instance iOS started without the test's arguments (a Live Activity's intent after a test that stopped
        // while recording) would otherwise be what the launch finds: German, not recording.
        XCUIApplication().terminate()
        let app = launch(["-autoRecord", "-fakeSilence"])            // nothing saved, see above
        if !app.buttons["Stop"].appears(timeout: 20) { print("APP-TREE", app.debugDescription) }
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
        XCTAssertTrue(stop.appears(timeout: 5), "Stop in the expanded island")
        shot("Dynamic Island expanded", springboard)
        stop.tap()
        app.activate()
        XCTAssertTrue(transcribe(app).appears(timeout: 15), "stopped: Transcribe again")
    }
}
