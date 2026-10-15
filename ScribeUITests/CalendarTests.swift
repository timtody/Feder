import XCTest

/// Name from Calendar (CalendarContext): a transcript started during a calendar event offers the event's name under its
/// date line (CalendarTitleRow: Use as Title, ⊗), on the recording card and in the saved transcript, and the rename
/// sheet offers the event's invitees. The name itself stays the app's own ("New Transcript N", then Gemma's title) until
/// Use as Title (FED-11). The simulator has no accounts with invitations, so `-fakeCalendarEvent`
/// puts events into the cache without EventKit (by default one from 10 minutes before the read to 50 minutes after it;
/// `Title@-60+420!flags` for others), and they run through the same rules as EventKit's, their attendees too (`*` the
/// user, `#` a room, `-` someone who declined, `~` someone copied in). `-calendarContext YES` turns it on for that
/// launch only (the argument domain), `-fakeCalendarAccess` answers the permission without the system alert.
/// Recordings are made with `-resetVoiceRecognition`, so naming a speaker of the fake recording stores no voice that
/// later tests' fake speakers would be recognized as.
final class CalendarTests: CalendarTestCase {
    /// Transcribe during "Design Review": the card keeps "New Transcript N" and offers the event under its date line;
    /// so does the saved transcript, also once the fake Gemma has titled it "Live Transcript Test". Use as Title names it
    /// "Design Review", and the row goes (FED-135: nothing more to take, renamed like any other name). The rename sheet offers the invitees (cleaned up, without the address, the user, the room and the one
    /// who declined) above the people; a tap names the speaker, and the next speaker's sheet says that invitee is
    /// already in this transcript.
    @MainActor
    func testEventIsOfferedAndInvitees() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Design Review|" + Self.attendees,
                          "-fakeGemma", "-resetVoiceRecognition"])
        startRecording(app)
        let row = calendarRow(app)
        XCTAssertTrue(row.appears(timeout: 5), "the event is offered while recording")
        XCTAssertEqual(row.label, "Calendar event “Design Review”")
        XCTAssertTrue(app.buttons["UseCalendarTitle"].exists && app.buttons["DismissCalendarTitle"].exists)
        XCTAssertTrue(hasDefaultTitle(app), "the card keeps New Transcript N")
        XCTAssertLessThan(recordingTitle(app).frame.maxY, row.frame.minY, "the row under the title")
        shot("Recording during a meeting: the event offered", app)
        sleep(9)                                            // two speakers: FakeDiarizer changes every 4 s
        app.buttons["Stop"].firstMatch.tap()

        let field = app.textFields["Title"]
        XCTAssertTrue(field.appears(timeout: 15), "the transcript in the card")
        XCTAssertTrue((field.value as? String)?.hasPrefix("New Transcript ") == true, "saved with the app's own name")
        XCTAssertTrue(waitFor { row.exists && row.label == "Calendar event “Design Review”" }, "offered in the transcript")
        shot("Saved: the event offered", app)
        // The summary comes after the speakers are final and the vocabulary pass, with Gemma's title.
        XCTAssertTrue(app.buttons["Summary"].appears(timeout: 40), "the summary is written")
        XCTAssertTrue(waitFor { (field.value as? String) == "Live Transcript Test" }, "Gemma titles it")
        XCTAssertEqual(row.label, "Calendar event “Design Review”", "still offered next to Gemma's title")
        XCTAssertLessThan(field.frame.maxY, row.frame.minY, "under the title")
        XCTAssertLessThan(row.frame.maxY, app.buttons["Summary"].frame.minY, "above the summary")
        shot("Gemma's title, the event offered", app)
        app.buttons["UseCalendarTitle"].tap()
        XCTAssertTrue(waitFor { (field.value as? String) == "Design Review" }, "Use as Title names it after the event")
        XCTAssertTrue(row.disappears(timeout: 5), "the row goes")
        XCTAssertFalse(app.buttons["DismissCalendarTitle"].exists, "no ⊗ either")
        shot("Named after the event", app)

        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).appears(timeout: 5), "the rename sheet")
        dismissKeyboardTip(app)
        let maria = app.buttons["PersonChoice.Maria Lopez"], tom = app.buttons["PersonChoice.Tom Berger"]
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        XCTAssertTrue(maria.appears(timeout: 3) && tom.exists, "the invitees, \"Berger, Tom\" as Tom Berger")
        XCTAssertTrue(app.staticTexts["Invitees"].exists, "in their own section")
        XCTAssertTrue(app.staticTexts["From the calendar event “Design Review”."].exists, "the footer names the event")
        XCTAssertTrue(maria.label.contains("Invited"), maria.label)
        for gone in ["tom@example.com", "Julius Taylor", "Room 4.12", "Paul Declined", "Carla Copied", "Anna Schmidt (Cofinpro)",
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
        XCTAssertTrue(nameField(app).disappears(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.0"].label, "Maria Lopez", "named like a typed name")
        app.buttons["SpeakerHeader.1"].tap()
        XCTAssertTrue(nameField(app).appears(timeout: 5))
        XCTAssertTrue(maria.appears(timeout: 3))
        XCTAssertTrue(maria.label.contains("Already in this transcript"), maria.label)
        shot("Invitee already in this transcript", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).disappears(timeout: 5))
        deleteOpenTranscript(app)                           // Maria goes with it
    }

    /// Use as Title while recording names the card after the event at once and the row goes (FED-135), and the
    /// transcript is saved so, without the row; Gemma's title (the fake's "Live Transcript Test") doesn't replace it,
    /// also after the card is closed and opened again.
    @MainActor
    func testUseAsTitleWhileRecordingIsKept() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Design Review|Maria Lopez", "-fakeGemma",
                          "-resetVoiceRecognition"])
        startRecording(app)
        let row = calendarRow(app)
        XCTAssertTrue(row.appears(timeout: 5), "the event is offered")
        app.buttons["UseCalendarTitle"].tap()
        XCTAssertTrue(waitFor(timeout: 2) { self.recordingTitle(app).label == "Design Review" },
                      "the card is named after the event at once")
        XCTAssertTrue(row.disappears(timeout: 3), "the row goes")
        XCTAssertFalse(app.buttons["DismissCalendarTitle"].exists, "no ⊗ either")
        shot("Recording named after the event", app)
        sleep(5)
        app.buttons["Stop"].firstMatch.tap()

        let field = app.textFields["Title"]
        XCTAssertTrue(field.appears(timeout: 15), "the transcript in the card")
        XCTAssertEqual(field.value as? String, "Design Review", "saved with the event's name")
        XCTAssertFalse(row.exists, "no row in the transcript")
        XCTAssertTrue(app.buttons["Summary"].appears(timeout: 40), "the summary is written")
        XCTAssertEqual(field.value as? String, "Design Review", "Gemma keeps the name taken from the calendar")
        shot("Gemma kept the event's name", app)
        closeCard(app)
        open("Design Review", in: app)
        XCTAssertFalse(row.appears(timeout: 2), "for good")
        deleteOpenTranscript(app)
    }

    /// ⊗ before Use as Title while recording only hides the offer: the name stays "New Transcript N", and the saved
    /// transcript shows no row either, also once the fake Gemma has titled it and after closing and opening it again.
    /// The event itself was saved (its invitee is offered in the rename sheet): the dismissal hides only the title.
    @MainActor
    func testDismissBeforeTakingWhileRecordingLasts() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Design Review|Maria Lopez", "-fakeGemma",
                          "-resetVoiceRecognition"])
        startRecording(app)
        let row = calendarRow(app)
        XCTAssertTrue(row.appears(timeout: 5), "the event is offered")
        let before = recordingTitle(app).label
        XCTAssertTrue(before.hasPrefix("New Transcript "), before)
        app.buttons["DismissCalendarTitle"].tap()
        XCTAssertTrue(row.disappears(timeout: 3), "⊗ hides the offer")
        XCTAssertEqual(recordingTitle(app).label, before, "the name stays")
        shot("Dismissed before taking, while recording", app)
        sleep(5)
        app.buttons["Stop"].firstMatch.tap()

        let field = app.textFields["Title"]
        XCTAssertTrue(field.appears(timeout: 15), "the transcript in the card")
        XCTAssertEqual(field.value as? String, before, "saved with the app's own name")
        XCTAssertFalse(row.appears(timeout: 2), "not offered in the transcript")
        XCTAssertTrue(app.buttons["Summary"].appears(timeout: 40), "the summary is written")
        XCTAssertTrue(waitFor { (field.value as? String) == "Live Transcript Test" }, "Gemma titles it")
        XCTAssertFalse(row.exists, "still not offered next to Gemma's title")
        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).appears(timeout: 5), "the rename sheet")
        dismissKeyboardTip(app)
        XCTAssertTrue(app.buttons["PersonChoice.Maria Lopez"].appears(timeout: 3), "the event was saved")
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).disappears(timeout: 5))
        closeCard(app)
        open("Live Transcript Test", in: app)
        XCTAssertFalse(row.appears(timeout: 2), "for good")
        shot("Saved after ⊗ before taking: no row", app)
        deleteOpenTranscript(app)
    }

    /// Project Kickoff as if started during "Kickoff Meeting" (`-seedInvitees`): the transcript offers it under the date
    /// line, above the AI notice. Use as Title names it so, also in the list, and the row goes for good. Launched again (the seed is fresh): ⊗ alone hides the offer for good, and typing a title takes
    /// it away too. In German the button says "Als Titel verwenden" and fits beside the event's name.
    @MainActor
    func testSeededOfferInTranscript() throws {
        var app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber"])
        open("Project Kickoff", in: app)
        var field = app.textFields["Title"], row = calendarRow(app)
        XCTAssertTrue(row.appears(timeout: 5), "the event is offered")
        XCTAssertEqual(row.label, "Calendar event “Kickoff Meeting”")
        XCTAssertLessThan(field.frame.maxY, row.frame.minY, "under the title")
        XCTAssertLessThan(row.frame.maxY, app.staticTexts["AINotice"].frame.minY, "above the AI notice")
        shot("Seeded offer", app)
        app.buttons["UseCalendarTitle"].tap()
        XCTAssertTrue(waitFor { (field.value as? String) == "Kickoff Meeting" }, "named after the event")
        XCTAssertTrue(row.disappears(timeout: 5), "the row goes")
        closeCard(app)
        XCTAssertTrue(app.staticTexts["Kickoff Meeting"].appears(timeout: 5), "the list says so too")
        open("Kickoff Meeting", in: app)
        XCTAssertFalse(row.appears(timeout: 2), "the row stays gone")

        app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber"])
        (field, row) = (app.textFields["Title"], calendarRow(app))
        open("Project Kickoff", in: app)
        XCTAssertTrue(row.appears(timeout: 5))
        app.buttons["DismissCalendarTitle"].tap()
        XCTAssertTrue(row.disappears(timeout: 5), "⊗ hides the offer")
        XCTAssertEqual(field.value as? String, "Project Kickoff", "the name stays")
        closeCard(app)
        open("Project Kickoff", in: app)
        XCTAssertFalse(row.appears(timeout: 2), "for good")

        app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber"])
        (field, row) = (app.textFields["Title"], calendarRow(app))
        open("Project Kickoff", in: app)
        XCTAssertTrue(row.appears(timeout: 5))
        field.tap()
        field.typeText(" Notes")
        XCTAssertTrue(row.disappears(timeout: 5), "a typed title takes the offer away")
        shot("Typed title: no offer", app)

        app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber", "-AppleLanguages", "(de)"])
        row = calendarRow(app)
        app.staticTexts["Project Kickoff"].firstMatch.tap()
        let use = app.buttons["UseCalendarTitle"], dismiss = app.buttons["DismissCalendarTitle"]
        XCTAssertTrue(use.appears(timeout: 10), "the German transcript offers it")
        XCTAssertEqual(use.label, "Als Titel verwenden")
        XCTAssertEqual(row.label, "Kalenderereignis „Kickoff Meeting“")
        XCTAssertEqual(dismiss.label, "Ignorieren")
        XCTAssertLessThan(row.frame.maxX, use.frame.minX + 1, "the event's name beside the button")
        XCTAssertLessThan(use.frame.maxX, dismiss.frame.minX + 1)
        XCTAssertLessThanOrEqual(dismiss.frame.maxX, app.frame.maxX, "all on screen")
        XCTAssertLessThan(abs(row.frame.midY - use.frame.midY), 4, "on one line")
        shot("German offer", app)
    }

    /// A press from outside the app (the lock screen widget's `feder://record`, as Control Center, the Action Button or
    /// Siri on a cold launch) that comes while the calendar's first read still runs (`-fakeCalendarDelay 25`, counted
    /// from launch) finds no event, and recording starts without waiting for the read; once the read has it, the card
    /// offers the event under its date line, and the name stays "New Transcript N". Not `-autoRecord`: XCUITest's launch
    /// waited minutes for an app that records from its first second to become idle.
    @MainActor
    func testColdStartOffersTheEventOnceRead() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Standup", "-fakeCalendarDelay", "25",
                          "-fakeSilence"])
        app.open(URL(string: "feder://record")!)
        XCTAssertTrue(app.buttons["Minimize"].appears(timeout: 10), "the card is up")
        XCTAssertTrue(app.staticTexts["Listening…"].appears(timeout: 15), "recording, not waiting for the read")
        let row = calendarRow(app)
        XCTAssertFalse(row.exists, "pressed during the read: nothing offered yet")
        XCTAssertTrue(hasDefaultTitle(app), "New Transcript N")
        shot("Recording before the read", app)
        XCTAssertTrue(row.appears(timeout: 40), "offered once the read has it")
        XCTAssertEqual(row.label, "Calendar event “Standup”")
        XCTAssertTrue(hasDefaultTitle(app), "the name stays New Transcript N")
        shot("Recording, the event offered after the read", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
    }

    /// On, with access but no event now: the transcript keeps "New Transcript N", and nothing is offered.
    @MainActor
    func testNoEventKeepsDefaultName() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarAccess", "granted", "-fakeSilence"])
        startRecording(app)
        XCTAssertTrue(waitFor { self.hasDefaultTitle(app) }, "no event: New Transcript N")
        XCTAssertFalse(calendarRow(app).exists, "nothing offered")
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "nothing saved, the card closes")
    }

    /// Project Kickoff as if started during "Kickoff Meeting" with Maria Lopez and Jonas Weber invited
    /// (`-seedInvitees`): the sheet lists both under Invitees, Jonas (a known person) once, there; the footer names the
    /// event; Anna, this speaker's person but not invited, stays on top in Suggestions (below the invitees she was off
    /// the half-height sheet); typing filters the invitees like the people.
    @MainActor
    func testSeededInviteesInRenameSheet() throws {
        let app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber"])
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).appears(timeout: 5))
        dismissKeyboardTip(app)
        let maria = app.buttons["PersonChoice.Maria Lopez"], jonas = app.buttons["PersonChoice.Jonas Weber"]
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        XCTAssertTrue(jonas.appears(timeout: 3), "the invitees")
        XCTAssertEqual(app.buttons.matching(identifier: "PersonChoice.Jonas Weber").count, 1, "Jonas once")
        let header = app.staticTexts["Invitees"]
        XCTAssertTrue(header.exists)
        XCTAssertLessThan(header.frame.minY, jonas.frame.minY)
        XCTAssertTrue(jonas.label.contains("Already in this transcript"), jonas.label)
        let suggestions = app.staticTexts["Suggestions"]
        XCTAssertTrue(anna.isHittable && suggestions.exists, "Anna, this speaker, on the half-height sheet, in Suggestions")
        XCTAssertTrue(anna.label.contains("This speaker"), anna.label)
        XCTAssertLessThan(suggestions.frame.minY, anna.frame.minY)
        XCTAssertLessThan(anna.frame.maxY, header.frame.minY, "above the invitees")
        shot("Seeded invitees", app)
        // The other invitees are below the half-height sheet's fold (List's rows there don't exist yet): pulled up by
        // the Invitees header (a swipe up on the bottom row started in the home gesture's area and went Home).
        for _ in 0..<2 where !maria.isHittable {
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(maria.appears(timeout: 3), "Maria, the other invitee")
        XCTAssertTrue(maria.label.contains("Invited"), maria.label)
        XCTAssertLessThan(jonas.frame.minY, maria.frame.minY, "by name")
        XCTAssertLessThan(header.frame.minY, jonas.frame.minY)
        XCTAssertTrue(app.staticTexts["From the calendar event “Kickoff Meeting”."].exists, "the footer names the event")
        shot("Seeded invitees, sheet pulled up", app)

        nameField(app).typeText("Ma")
        XCTAssertTrue(maria.appears(timeout: 3))
        XCTAssertTrue(jonas.disappears(timeout: 3), "typing filters the invitees")
        XCTAssertTrue(anna.disappears(timeout: 3), "and the suggestions")
        shot("Invitees filtered", app)
        app.buttons["CancelRename"].tap()
    }

    /// Which event is offered, one launch per calendar: the one starting closest to the press, also up to
    /// 5 minutes before it starts, not the all-day workshop around it; never an all-day, cancelled or declined one,
    /// nor one starting in 6 minutes, though each would be closer; someone else's event in a calendar shared with the
    /// user read-only never, even when nothing else runs (a partner's "Therapy" offered for the user's own memo), nor one in
    /// a subscribed calendar (the fake's Outlook) while it isn't the Preferred Calendar; the user's own events first,
    /// also in a shared calendar they are invited in, before a closer one they aren't on. (No apostrophes in the titles:
    /// XCUITest's launch arguments mangle them, "Partner's Therapy@…" arrived without its flags.) In the first, ⊗ before
    /// Use as Title only hides the offer.
    @MainActor
    func testWhichEventIsOffered() throws {
        let cases: [(calendar: String, name: String?, not: [String])] = [
            ("Workshop@-60+420;Standup@+4+15", "Standup", ["Workshop"]),
            ("Workshop@-60+420;Too Early@+6+30;Offsite@-1+600!allday;Cancelled@-1+30!canceled;Declined@-1+30!declined",
             "Workshop", ["Too Early", "Offsite", "Cancelled", "Declined"]),
            // Neither counts while it isn't the Preferred Calendar: someone else's in a shared calendar, a subscribed one
            // (one launch for both: either one offered fails it).
            ("Therapy@-1+60!shared;Client Call@-1+60!cal=Outlook", nil, ["Therapy", "Client Call"]),
            ("Therapy@-1+60!shared;Board Meeting@-2+60!others|Anna Schmidt|Tom Berger;Team Sync@-3+30!shared|*Julius Taylor|Maria Lopez",
             "Team Sync", ["Therapy", "Board Meeting"]),
        ]
        for (index, (calendar, name, not)) in cases.enumerated() {
            let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", calendar, "-fakeSilence"])
            startRecording(app)
            assertOffers(name, not: not, app, "\(calendar)")
            shot(name ?? "No event", app)
            if index == 0 {
                let title = recordingTitle(app).label
                app.buttons["DismissCalendarTitle"].tap()
                XCTAssertTrue(calendarRow(app).disappears(timeout: 3), "⊗ hides the offer")
                XCTAssertEqual(recordingTitle(app).label, title, "the name stays")
            }
            app.buttons["Stop"].firstMatch.tap()            // -fakeSilence: nothing saved, the card closes
            XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
        }
    }

    /// A press that resumes a suspended Feder (Control Center, the Action Button, the widget) picks from what was read
    /// before: here "Weekly Sync", which was moved two hours later on another device meanwhile (`-fakeCalendarEventLater`
    /// from 10 s after launch). Once the read the return starts (5 s, `-fakeCalendarDelay`) has ended, the offer goes;
    /// recording didn't wait for it. The URL goes through the system (`XCUIDevice.shared.system.open`):
    /// `XCUIApplication.open` relaunches the app, a cold start.
    @MainActor
    func testResumePicksTheEventAgain() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Weekly Sync",
                          "-fakeCalendarEventLater", "Weekly Sync@+120+60", "-fakeCalendarLaterAfter", "10",
                          "-fakeCalendarDelay", "5", "-fakeSilence"])
        sleep(12)                                           // the launch's read has ended; the calendar has changed
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitFor(timeout: 15) { [.runningBackground, .runningBackgroundSuspended].contains(app.state) },
                      "in the background")
        XCUIDevice.shared.system.open(URL(string: "feder://record")!)
        XCTAssertTrue(app.buttons["Minimize"].appears(timeout: 10), "the card is up")
        let row = calendarRow(app)
        XCTAssertTrue(row.exists && row.label == "Calendar event “Weekly Sync”",
                      "the press picked from the cache read before the change")
        shot("Picked from the old read", app)
        XCTAssertTrue(row.disappears(timeout: 15), "gone once the new read has ended")
        XCTAssertTrue(app.staticTexts["Listening…"].exists, "recording meanwhile")
        XCTAssertTrue(hasDefaultTitle(app), "New Transcript N")
        shot("Recording, the moved meeting gone", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
    }
}

/// Name from Calendar's switch and Settings: turned off while recording, turned on (also from the iPhone's Settings),
/// the Preferred Calendar and a subscribed one. Apart from CalendarTests so a parallel run gives each half a worker
/// (the class was the longest, 14 minutes of 18).
final class CalendarSettingsTests: CalendarTestCase {
    /// Name from Calendar turned off while recording (the card minimized, Settings, back): the card's row is gone, and
    /// the transcript keeps the name it showed (the event's, taken with Use as Title), but no event is saved with it,
    /// as Save Location keeps no place then: no row in the transcript, and its rename sheet has no Invitees.
    /// `-calendarOn` (stored, so the switch can turn it off) and off again at the end.
    @MainActor
    func testSwitchedOffBeforeStopSavesNoInvitees() throws {
        let app = launch(["-calendarOn", "-fakeCalendarEvent", "Design Review|Maria Lopez|Berger, Tom",
                          "-fakeGemma", "-resetVoiceRecognition"])
        startRecording(app)
        XCTAssertTrue(calendarRow(app).appears(timeout: 5), "the event is offered")
        app.buttons["UseCalendarTitle"].tap()
        XCTAssertTrue(waitFor(timeout: 3) { self.recordingTitle(app).label == "Design Review" },
                      "the card is named after the event")
        setCalendarSwitch(false, whileRecording: app)
        XCTAssertFalse(calendarRow(app).exists, "taken: no row (FED-135)")
        XCTAssertEqual(recordingTitle(app).label, "Design Review", "the name stays as shown")
        sleep(6)                                            // two speakers: FakeDiarizer changes every 4 s
        app.buttons["Stop"].firstMatch.tap()

        let field = app.textFields["Title"]
        XCTAssertTrue(field.appears(timeout: 15), "the transcript in the card")
        XCTAssertEqual(field.value as? String, "Design Review", "the name stays as shown")
        XCTAssertFalse(calendarRow(app).appears(timeout: 2), "no event saved: no row")
        // Names can be changed once the speakers are final; the summary comes after that.
        XCTAssertTrue(app.buttons["Summary"].appears(timeout: 40), "the speakers are final")
        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).appears(timeout: 5), "the rename sheet")
        dismissKeyboardTip(app)
        XCTAssertFalse(app.staticTexts["Invitees"].exists, "no invitees saved")
        XCTAssertFalse(app.buttons["PersonChoice.Maria Lopez"].exists)
        shot("No invitees after turning it off", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).disappears(timeout: 5))
        deleteOpenTranscript(app)
    }

    /// Name from Calendar turned off while recording, before Use as Title: the card's row is gone at once, so the
    /// meeting's name can't be taken any more (Stop saves no event then, so nothing could give the app's name back);
    /// turned on again before Stop, it is offered again. `-calendarOn` (stored, so the switch can turn it off), and off
    /// at the end.
    @MainActor
    func testSwitchedOffWhileRecordingTakesTheOfferAway() throws {
        let app = launch(["-calendarOn", "-fakeCalendarEvent", "Design Review", "-fakeSilence"])
        startRecording(app)
        let row = calendarRow(app)
        XCTAssertTrue(row.appears(timeout: 5), "the event is offered")
        setCalendarSwitch(false, whileRecording: app)
        XCTAssertFalse(row.appears(timeout: 2), "the row went with the switch")
        XCTAssertFalse(app.buttons["UseCalendarTitle"].exists, "nothing to take")
        XCTAssertTrue(hasDefaultTitle(app), "New Transcript N")
        shot("Recording after Name from Calendar was turned off", app)
        setCalendarSwitch(true, whileRecording: app)
        XCTAssertTrue(row.appears(timeout: 10), "on again: offered again")
        XCTAssertEqual(row.label, "Calendar event “Design Review”")
        setCalendarSwitch(false, whileRecording: app)
        XCTAssertFalse(row.appears(timeout: 2), "off for the next tests")
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
    }

    /// Settings' switch asks for access (answered by `-fakeCalendarAccess granted`, no system alert) and turns on;
    /// off again for the next tests.
    @MainActor
    func testSwitchTurnsOn() throws {
        let app = launch(["-resetCalendar", "-fakeCalendarAccess", "granted"])
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        XCTAssertTrue(toggle.appears(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (toggle.value as? String) == "1" }, "on once access is given")
        shot("Name from Calendar on", app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (toggle.value as? String) == "0" }, "off again")
    }

    /// Denied before (`-fakeCalendarAccess deniedFirst`: no system alert then, and allowed from then on, as if in the
    /// iPhone's Settings): the switch offers Open Settings, which opens the Settings app; back in Feder with access
    /// given, the switch is on without a second tap. Off again for the next tests.
    @MainActor
    func testOpenSettingsTurnsItOnOnReturn() throws {
        let app = launch(["-resetCalendar", "-fakeCalendarAccess", "deniedFirst"])
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        XCTAssertTrue(toggle.appears(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let alert = app.alerts["Allow Calendar Access"]
        XCTAssertTrue(alert.appears(timeout: 5), "it offers the iPhone's Settings")
        alert.buttons["Open Settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "the Settings app")
        app.activate()
        XCTAssertTrue(toggle.appears(timeout: 10))
        XCTAssertTrue(waitFor(timeout: 10) { (toggle.value as? String) == "1" }, "on when back with access given")
        shot("Back from Settings: on", app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (toggle.value as? String) == "0" }, "off again")
    }

    /// Settings' Preferred Calendar (the fake's calendars: iCloud's Home and Work, Exchange's Calendar, the subscribed
    /// Outlook: testSubscribedCalendarCountsWhenPreferred): below the switch while it is on, None by default. Its page
    /// lists None, then the calendars by account; Work chosen there, the recording offers "Planning" in Work, though
    /// "Standup" in Home started closer to the press (without a preference Standup is offered:
    /// testWhichEventIsOffered). None again at the end.
    @MainActor
    func testPreferredCalendarWins() throws {
        let app = launch(["-resetCalendar", "-calendarContext", "YES",
                          "-fakeCalendarEvent", "Planning@-30+90!cal=Work;Standup@-1+15", "-fakeSilence"])
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        let row = preferredRow(app)
        XCTAssertTrue(row.appears(timeout: 5), "below the switch while it is on")
        XCTAssertTrue(shown(row).contains("None"), "None by default: \(shown(row))")
        XCTAssertLessThanOrEqual(toggle.frame.maxY, row.frame.minY + 1, "below Name from Calendar")
        XCTAssertLessThanOrEqual(row.frame.maxY, app.switches["Save Location"].firstMatch.frame.minY + 1, "above Save Location")
        row.tap()

        XCTAssertTrue(app.navigationBars["Preferred Calendar"].appears(timeout: 5), "its own page")
        let none = app.buttons["None"].firstMatch, calendar = app.buttons["Calendar"].firstMatch
        let home = app.buttons["Home"].firstMatch, work = app.buttons["Work"].firstMatch
        XCTAssertTrue(none.exists && calendar.exists && home.exists && work.exists, "None and the three calendars")
        XCTAssertTrue(none.isSelected, "None checked")
        XCTAssertLessThan(none.frame.minY, calendar.frame.minY, "None first")
        XCTAssertLessThan(calendar.frame.minY, home.frame.minY, "by account: Exchange, then iCloud")
        XCTAssertLessThan(home.frame.minY, work.frame.minY)
        for account in ["Exchange", "iCloud"] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", account)).firstMatch.exists,
                          "\(account)'s section")
        }
        shot("Preferred Calendar", app)
        work.tap()
        XCTAssertTrue(row.appears(timeout: 5), "back in Settings")
        XCTAssertTrue(waitFor { self.shown(row).contains("Work") }, "Work chosen: \(shown(row))")
        shot("Preferred Calendar: Work", app)

        startRecording(app)
        assertOffers("Planning", not: ["Standup"], app, "the event in the preferred calendar, not the closer one in Home")
        shot("The preferred calendar's event offered", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(row.appears(timeout: 5))
        row.tap()
        XCTAssertTrue(none.appears(timeout: 5))
        XCTAssertTrue(work.isSelected, "Work checked")
        none.tap()
        XCTAssertTrue(row.appears(timeout: 5))
        XCTAssertTrue(waitFor { self.shown(row).contains("None") }, "None again: \(shown(row))")
    }

    /// A subscribed calendar (the fake's "Outlook": an Outlook calendar published as a link, read-only, whose events
    /// don't mark the user: `others`, no organizer, no attendees) is on Preferred Calendar's page, last, under Subscribed
    /// Calendars, and counts only once it is chosen there. Someone else's event in a calendar the user can only read
    /// counts the same way ("Therapy", shared with the user in Home). "Client Call" and "Therapy" started closer to the
    /// press than "Planning" in Work and, without attendees, rank like the user's own, so with None either would be
    /// offered if it counted unchosen: Planning is. With Outlook chosen "Client Call" is offered, with Home chosen
    /// "Therapy". None again at the end.
    @MainActor
    func testSubscribedCalendarCountsWhenPreferred() throws {
        let app = launch(["-resetCalendar", "-calendarContext", "YES", "-fakeCalendarEvent",
                          "Client Call@-1+60!cal=Outlook,others;Therapy@-2+60!shared;Planning@-30+90!cal=Work", "-fakeSilence"])
        record(named: "Planning", not: ["Client Call", "Therapy"], app)

        app.buttons["Settings"].firstMatch.tap()
        let row = preferredRow(app)
        XCTAssertTrue(row.appears(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Preferred Calendar"].appears(timeout: 5), "its own page")
        let work = app.buttons["Work"].firstMatch, outlook = app.buttons["Outlook"].firstMatch
        let section = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Subscribed Calendars")).firstMatch
        XCTAssertTrue(outlook.appears(timeout: 5) && section.exists, "Outlook under Subscribed Calendars")
        XCTAssertLessThan(work.frame.maxY, section.frame.minY, "after the accounts")
        XCTAssertLessThan(section.frame.maxY, outlook.frame.minY)
        shot("Preferred Calendar with a subscription", app)
        outlook.tap()
        XCTAssertTrue(row.appears(timeout: 5), "back in Settings")
        XCTAssertTrue(waitFor { self.shown(row).contains("Outlook") }, "Outlook chosen: \(shown(row))")
        shot("Preferred Calendar: Outlook", app)
        record(named: "Client Call", not: ["Planning", "Therapy"], app)

        choose("Home", row, app)
        record(named: "Therapy", not: ["Planning", "Client Call"], app)
        choose("None", row, app)
    }

    /// Transcribe; the card offers `name`, not any of `others`; Stop (`-fakeSilence`: nothing saved, the card closes).
    @MainActor
    private func record(named name: String, not others: [String], _ app: XCUIApplication) {
        startRecording(app)
        assertOffers(name, not: others, app, name)
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
    }

    /// Settings › Preferred Calendar › `calendar`, back in Settings with it shown.
    @MainActor
    private func choose(_ calendar: String, _ row: XCUIElement, _ app: XCUIApplication) {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(row.appears(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Preferred Calendar"].appears(timeout: 5), "its own page")
        let option = app.buttons[calendar].firstMatch
        XCTAssertTrue(option.appears(timeout: 5), calendar)
        option.tap()
        XCTAssertTrue(row.appears(timeout: 5), "back in Settings")
        XCTAssertTrue(waitFor { self.shown(row).contains(calendar) }, "\(calendar) chosen: \(shown(row))")
    }

    /// The preferred calendar's identifier changed since it was chosen (`-fakeCalendarResynced`: a full sync; Apple says
    /// identifiers can change then): it is found again by its name and account, and its event still wins. A preferred
    /// calendar that is gone counts as None: the closer Standup is offered, and Settings says None.
    @MainActor
    func testPreferredCalendarAfterResync() throws {
        let events = "Planning@-30+90!cal=Work;Standup@-1+15"
        for (preferred, name) in [("Work", "Planning"), ("Gone", "Standup")] {
            let app = launch(["-resetCalendar", "-calendarContext", "YES", "-preferFakeCalendar", preferred,
                              "-fakeCalendarResynced", "YES", "-fakeCalendarEvent", events, "-fakeSilence"])
            startRecording(app)
            assertOffers(name, not: [], app, "\(preferred)")
            app.buttons["Stop"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
            app.buttons["Settings"].firstMatch.tap()
            let row = preferredRow(app)
            XCTAssertTrue(row.appears(timeout: 5))
            XCTAssertTrue(shown(row).contains(preferred == "Gone" ? "None" : "Work"), "\(preferred): \(shown(row))")
            shot("Preferred \(preferred) after a resync", app)
        }
    }
}

/// What both calendar classes share: the fake event's attendees, the row, the recording card's title, the switch.
class CalendarTestCase: ScribeUITestCase {
    /// The event's attendees as EventKit could give them: two people (one "Last, First"), an address, the user, a room,
    /// someone who declined, someone copied in without taking part, and a known person with Exchange's company suffix.
    static let attendees = "Maria Lopez|Berger, Tom|tom@example.com|*Julius Taylor|#Room 4.12|-Paul Declined|~Carla Copied|Schmidt, Anna (Cofinpro)"

    /// The calendar row's event (CalendarTitleRow), under the date line of the recording card or
    /// the transcript.
    func calendarRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["CalendarTitle"].firstMatch
    }

    /// The recording card's title (not a list row under the card: test runs that failed left transcripts behind).
    func recordingTitle(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["RecordingTitle"].firstMatch
    }

    /// The recording card's title is the app's own ("New Transcript N").
    @MainActor
    func hasDefaultTitle(_ app: XCUIApplication) -> Bool {
        let title = recordingTitle(app)
        return title.exists && title.label.hasPrefix("New Transcript ") && title.isHittable
    }

    /// The recording card offers `name` (nil: nothing) under its date line, none of `others`, and keeps its own name.
    @MainActor
    func assertOffers(_ name: String?, not others: [String], _ app: XCUIApplication, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let row = calendarRow(app)
        if let name {
            XCTAssertTrue(row.appears(timeout: 10), "\(message): offered", file: file, line: line)
            XCTAssertEqual(row.label, "Calendar event “\(name)”", message, file: file, line: line)
        } else {
            XCTAssertFalse(row.appears(timeout: 2), "\(message): nothing offered", file: file, line: line)
        }
        for other in others {
            XCTAssertFalse(row.exists && row.label.contains(other), "\(message): not \(other)", file: file, line: line)
        }
        XCTAssertTrue(waitFor { self.hasDefaultTitle(app) }, "\(message): New Transcript N", file: file, line: line)
    }

    /// Minimizes the recording card, turns Settings' Name from Calendar `on` or off, and goes back to the card from the
    /// accessory; it records all along.
    @MainActor
    func setCalendarSwitch(_ on: Bool, whileRecording app: XCUIApplication, file: StaticString = #filePath,
                                   line: UInt = #line) {
        app.buttons["Minimize"].tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "minimized", file: file, line: line)
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        XCTAssertTrue(toggle.appears(timeout: 5), "Settings", file: file, line: line)
        XCTAssertEqual(toggle.value as? String, on ? "0" : "1", on ? "was off" : "was on", file: file, line: line)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (toggle.value as? String) == (on ? "1" : "0") }, on ? "on" : "off", file: file, line: line)
        app.buttons["Recording"].firstMatch.tap()           // back to the card from the accessory
        XCTAssertTrue(app.buttons["Minimize"].appears(timeout: 5), "the card again", file: file, line: line)
    }

    /// Settings' Preferred Calendar row (a navigation-link picker: a button labelled with its name, the choice its value).
    func preferredRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preferred Calendar'")).firstMatch
    }

    func shown(_ row: XCUIElement) -> String {
        "\(row.label) \(row.value as? String ?? "")"
    }

}
