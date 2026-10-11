import XCTest

/// Name from Calendar (CalendarContext): a transcript started during a calendar event gets the event's name, and the
/// rename sheet offers the event's invitees. The simulator has no accounts with invitations, so `-fakeCalendarEvent`
/// puts one event (from 10 minutes before the read to 50 minutes after it) into the cache without EventKit; its
/// attendees run through the same rules as EventKit's (`*` the user, `#` a room, `-` someone who declined).
/// `-calendarContext YES` turns it on for that launch only (the argument domain), `-fakeCalendarAccess` answers the
/// permission without the system alert. Recordings are made with `-resetVoiceRecognition`, so naming a speaker of the
/// fake recording stores no voice that later tests' fake speakers would be recognized as.
final class CalendarTests: ScribeUITestCase {
    /// The event's attendees as EventKit could give them: two people (one "Last, First"), an address, the user, a room,
    /// someone who declined, and a known person with Exchange's company suffix.
    static let attendees = "Maria Lopez|Berger, Tom|tom@example.com|*Julius Taylor|#Room 4.12|-Paul Declined|Schmidt, Anna (Cofinpro)"

    /// Transcribe during "Design Review": the card's title is the event's name from the start, the transcript keeps it
    /// (also after Gemma's summary: a calendar name isn't a default name), and the rename sheet offers the invitees
    /// (cleaned up, without the address, the user, the room and the one who declined) above the people; a tap names the
    /// speaker, and the next speaker's sheet says that invitee is already in this transcript.
    @MainActor
    func testEventNamesTranscriptAndOffersInvitees() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Design Review|" + Self.attendees,
                          "-fakeGemma", "-resetVoiceRecognition"])
        startRecording(app)
        XCTAssertTrue(app.staticTexts["Design Review"].waitForExistence(timeout: 5), "the card is named after the event")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '"))
                        .allElementsBoundByIndex.contains { $0.isHittable }, "not New Transcript N")
        shot("Recording named after the event", app)
        sleep(9)                                            // two speakers: FakeDiarizer changes every 4 s
        app.buttons["Stop"].firstMatch.tap()

        let field = app.textFields["Title"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the transcript in the card")
        XCTAssertEqual(field.value as? String, "Design Review", "saved with the event's name")
        // The summary comes after the speakers are final and the vocabulary pass: Gemma wrote only the summary.
        XCTAssertTrue(app.buttons["Summary"].waitForExistence(timeout: 40), "the summary is written")
        XCTAssertEqual(field.value as? String, "Design Review", "Gemma keeps a calendar name")

        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).waitForExistence(timeout: 5), "the rename sheet")
        dismissKeyboardTip(app)
        let maria = app.buttons["PersonChoice.Maria Lopez"], tom = app.buttons["PersonChoice.Tom Berger"]
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        XCTAssertTrue(maria.waitForExistence(timeout: 3) && tom.exists, "the invitees, \"Berger, Tom\" as Tom Berger")
        XCTAssertTrue(app.staticTexts["Invitees"].exists, "in their own section")
        XCTAssertTrue(app.staticTexts["From the calendar event “Design Review”."].exists, "the footer names the event")
        XCTAssertTrue(maria.label.contains("Invited"), maria.label)
        for gone in ["tom@example.com", "Julius Taylor", "Room 4.12", "Paul Declined", "Anna Schmidt (Cofinpro)",
                     "Schmidt, Anna (Cofinpro)"] {
            XCTAssertFalse(app.buttons["PersonChoice.\(gone)"].exists, "\(gone) is not offered")
        }
        // Anna is a known person (seeded): offered once, as an invitee, above the people.
        XCTAssertEqual(app.buttons.matching(identifier: "PersonChoice.Anna Schmidt").count, 1, "Anna once")
        XCTAssertTrue(anna.exists, "Anna among the invitees")
        // By name within the section: Anna, Maria, Tom (among the people she would come after Tom).
        XCTAssertLessThan(anna.frame.minY, maria.frame.minY, "Anna among the invitees, by name")
        XCTAssertLessThan(maria.frame.minY, tom.frame.minY)
        let jonas = app.buttons["PersonChoice.Jonas Weber"]
        if jonas.exists { XCTAssertLessThan(tom.frame.minY, jonas.frame.minY, "the invitees above the people") }
        shot("Invitees", app)

        maria.tap()
        XCTAssertTrue(nameField(app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.0"].label, "Maria Lopez", "named like a typed name")
        app.buttons["SpeakerHeader.1"].tap()
        XCTAssertTrue(nameField(app).waitForExistence(timeout: 5))
        XCTAssertTrue(maria.waitForExistence(timeout: 3))
        XCTAssertTrue(maria.label.contains("Already in this transcript"), maria.label)
        shot("Invitee already in this transcript", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).waitForNonExistence(timeout: 5))

        // Deleted again, so test recordings don't pile up in the simulator's store (Maria goes with it).
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "the card closes")
    }

    /// A press from outside the app (the lock screen widget's `feder://record`, as Control Center, the Action Button or
    /// Siri on a cold launch) that comes while the calendar's first read still runs (`-fakeCalendarDelay 45`, counted
    /// from launch) finds no event: the card shows no event name while preparing (`-fakePrepareSeconds 44`), and takes
    /// it once the read has it, before recording starts. Not `-autoRecord`: XCUITest's launch waited minutes for an app
    /// that records from its first second to become idle, long past the read.
    @MainActor
    func testColdStartTakesTheEvent() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Standup", "-fakeCalendarDelay", "45",
                          "-fakePrepareSeconds", "44", "-fakeSilence"])
        app.open(URL(string: "feder://record")!)
        let named = app.staticTexts["Standup"]
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10), "the card is up")
        XCTAssertFalse(named.exists, "pressed during the read: not named after the event yet")
        XCTAssertFalse(app.staticTexts["Listening…"].exists || app.buttons["Stop"].exists, "still preparing")
        shot("Preparing, before the read", app)
        XCTAssertTrue(named.waitForExistence(timeout: 60), "the event's name once the read has it")
        XCTAssertTrue(app.staticTexts["Listening…"].waitForExistence(timeout: 10), "then recording")
        XCTAssertTrue(named.exists, "the name stays while recording")
        shot("Recording, named after the event", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "the card closes")
    }

    /// A read slower than the wait (`-fakeCalendarDelay 90`, preparing quick) doesn't hold up recording: after preparing
    /// the press waits at most 1 s for it, then records as "New Transcript N", and the name stays when the read ends.
    @MainActor
    func testSlowReadDoesNotHoldUpRecording() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Standup", "-fakeCalendarDelay", "90",
                          "-fakeSilence"])
        app.open(URL(string: "feder://record")!)
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10), "the card is up")
        XCTAssertTrue(app.staticTexts["Listening…"].waitForExistence(timeout: 30), "recording, not waiting for the read")
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '"))
        XCTAssertTrue(title.allElementsBoundByIndex.contains { $0.isHittable }, "New Transcript N")
        XCTAssertFalse(app.staticTexts["Standup"].exists, "the read hasn't ended")
        shot("Recording before a slow read", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "the card closes")
    }

    /// On, with access but no event now: the transcript keeps "New Transcript N".
    @MainActor
    func testNoEventKeepsDefaultName() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarAccess", "granted", "-fakeSilence"])
        startRecording(app)
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '"))
        XCTAssertTrue(title.firstMatch.waitForExistence(timeout: 5) && title.allElementsBoundByIndex.contains { $0.isHittable },
                      "no event: New Transcript N")
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "nothing saved, the card closes")
    }

    /// Project Kickoff as if started during "Kickoff Meeting" with Maria Lopez and Jonas Weber invited
    /// (`-seedInvitees`): the sheet lists both under Invitees, Jonas (a known person) once, there; the footer names the
    /// event; typing filters the invitees like the people.
    @MainActor
    func testSeededInviteesInRenameSheet() throws {
        let app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber"])
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).waitForExistence(timeout: 5))
        dismissKeyboardTip(app)
        let maria = app.buttons["PersonChoice.Maria Lopez"], jonas = app.buttons["PersonChoice.Jonas Weber"]
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        XCTAssertTrue(maria.waitForExistence(timeout: 3) && jonas.exists, "the invitees")
        XCTAssertEqual(app.buttons.matching(identifier: "PersonChoice.Jonas Weber").count, 1, "Jonas once")
        let header = app.staticTexts["Invitees"]
        XCTAssertTrue(header.exists)
        XCTAssertLessThan(header.frame.minY, maria.frame.minY)
        XCTAssertLessThan(header.frame.minY, jonas.frame.minY)
        XCTAssertTrue(app.staticTexts["From the calendar event “Kickoff Meeting”."].exists, "the footer names the event")
        XCTAssertTrue(maria.label.contains("Invited"), maria.label)
        XCTAssertTrue(jonas.label.contains("Already in this transcript"), jonas.label)
        shot("Seeded invitees", app)
        // Anna, this speaker's person, is under People below the invitees: the half-height sheet shows only the
        // invitees, so it is pulled up first (List's rows below the fold don't exist yet), by its Invitees header: a
        // swipe up on the bottom row started in the home gesture's area and sent the app to the Home Screen.
        for _ in 0..<2 where !anna.isHittable {
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(anna.exists, "Anna, this speaker, under People")
        XCTAssertLessThan(jonas.frame.minY, anna.frame.minY, "the invitees above the people")
        XCTAssertTrue(anna.label.contains("This speaker"), anna.label)
        shot("Seeded invitees, sheet pulled up", app)

        nameField(app).typeText("Ma")
        XCTAssertTrue(maria.waitForExistence(timeout: 3))
        XCTAssertTrue(jonas.waitForNonExistence(timeout: 3), "typing filters the invitees")
        shot("Invitees filtered", app)
        app.buttons["CancelRename"].tap()
    }

    /// The onboarding's Calendar page (`-calendarOnboardingShown NO`): its rows; "Name from Calendar" asks for access
    /// (answered by `-fakeCalendarAccess granted`, no system alert) and turns it on: Settings shows the switch on.
    @MainActor
    func testCalendarPageTurnsItOn() throws {
        let app = launch(["-calendarOnboardingShown", "NO", "-resetCalendar", "-fakeCalendarAccess", "granted"])
        let title = app.staticTexts["Name Transcripts from Your Calendar"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the Calendar page")
        XCTAssertTrue(app.staticTexts["Named After the Meeting"].exists)
        XCTAssertTrue(app.staticTexts["Invitees as Speaker Names"].exists)
        XCTAssertTrue(app.staticTexts["Stays on This iPhone"].exists)
        XCTAssertTrue(app.buttons["No Thanks"].exists, "two large buttons decide it")
        shot("Calendar page", app)
        app.buttons["Name from Calendar"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "answered: the sheet goes on (here it ends)")

        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "on")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()   // off again for the next tests
        XCTAssertEqual(toggle.value as? String, "0", "off")
    }
}
