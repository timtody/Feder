import XCTest

/// How fast the app answers a press. The timings themselves come from the app (`-interactionTrace`: one log line per
/// press, see InteractionTrace); these tests drive every interaction path once so they can be captured with
/// `log stream`, and check that the record button opens the card without waiting for the speech model.
final class ResponsivenessTests: ScribeUITestCase {

    /// Transcribe, minimize, reopen, Stop, a row, Add Tag, Go to Person, the tabs and typing in Search, one after the other, with
    /// `-interactionTrace` logging each press's main-thread turn and first frame.
    @MainActor
    func testInteractionPathsTrace() throws {
        let app = launch(["-interactionTrace"])
        let record = transcribe(app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        settle()
        record.tap()
        XCTAssertTrue(app.buttons["Stop"].firstMatch.waitForExistence(timeout: 10), "the card with the large Stop")
        settle(2)                                                            // a few words are transcribed
        app.buttons["Minimize"].tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
        settle()
        app.buttons["Recording"].firstMatch.tap()                            // reopen from the accessory
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 5))
        settle()
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Share Transcript"].waitForExistence(timeout: 15), "the transcript's toolbar")
        settle(2)
        closeCard(app)
        settle()
        open("Project Kickoff", in: app)
        settle()
        app.buttons["Add Tag"].tap()                                         // the tag field after the pills
        XCTAssertTrue(app.textFields["Add Tag"].waitForExistence(timeout: 5))
        settle()
        app.typeText("\n")                                                  // Return in the empty field: done
        settle()
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)
        app.buttons["Go to Person"].tap()                                    // the card shrinks, then her page
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 10))
        settle(2)                                                            // her quotes are read
        app.navigationBars["Anna Schmidt"].buttons.firstMatch.tap()          // Back to the list
        settle()
        for tab in ["Settings", "Transcripts", "Search"] {
            app.buttons[tab].firstMatch.tap()
            settle()
        }
        XCTAssertTrue(app.textFields["SearchField"].waitForExistence(timeout: 5))
        dismissKeyboardTip(app)
        for character in "budget" {                                          // one keystroke at a time
            app.typeText(String(character))
            settle(0.5)
        }
        settle(1)
        app.buttons["Close"].firstMatch.tap()
        settle()
        deleteNewestRecording(app)
    }

    /// The record button reacts at once: the card is up (its Minimize control and the transcript's name) long before
    /// preparation is over (`-fakePrepareSeconds 6`: the fake speech model takes 6 s to prepare), and the large Stop
    /// follows once it is. (XCUITest itself takes 1-2 s to tap and to see the card, so the bound is loose; the
    /// timings themselves come from InteractionTrace.)
    @MainActor
    func testTranscribeOpensCardBeforePreparationFinishes() throws {
        let app = launch(["-fakePrepareSeconds", "6"])
        let record = transcribe(app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let tapped = Date.now
        record.tap()
        let minimize = app.buttons["Minimize"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 3), "the card opens without waiting for preparation")
        let opened = Date.now.timeIntervalSince(tapped)
        note("Card opened", "\(opened) s after the tap (preparation takes 6 s)")
        XCTAssertLessThan(opened, 4, "the card is up long before preparation is over: \(opened) s")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '")).firstMatch.exists,
                      "the name the transcript will get is shown from the start")
        XCTAssertFalse(app.buttons["Stop"].firstMatch.exists, "no Stop before the model is prepared")
        shot("Card before preparation", app)
        XCTAssertTrue(app.buttons["Stop"].firstMatch.waitForExistence(timeout: 12), "the Stop once prepared")
        XCTAssertGreaterThan(Date.now.timeIntervalSince(tapped), 5, "preparation really took its time")
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(minimize.waitForNonExistence(timeout: 15) || app.buttons["Share Transcript"].waitForExistence(timeout: 15))
        if app.buttons["Share Transcript"].exists {
            closeCard(app)
            deleteNewestRecording(app)
        }
    }

    /// Lets the app come to rest between presses, so one press's work doesn't run into the next measurement.
    @MainActor
    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: .now + seconds)
    }

    /// Deletes the transcript recorded by the test (the newest, listed with today's time), so test recordings don't
    /// pile up in the simulator's store.
    @MainActor
    private func deleteNewestRecording(_ app: XCUIApplication) {
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Today at '"))
        guard rows.firstMatch.waitForExistence(timeout: 5), !rows.element(boundBy: 0).label.hasPrefix("Project Kickoff") else { return }
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 10))
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
    }
}
