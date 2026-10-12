import XCTest

/// Name from Calendar (CalendarContext): a transcript started during a calendar event gets the event's name, and the
/// rename sheet offers the event's invitees. The simulator has no accounts with invitations, so `-fakeCalendarEvent`
/// puts events into the cache without EventKit (by default one from 10 minutes before the read to 50 minutes after it;
/// `Title@-60+420!flags` for others), and they run through the same rules as EventKit's, their attendees too (`*` the
/// user, `#` a room, `-` someone who declined, `~` someone copied in). `-calendarContext YES` turns it on for that
/// launch only (the argument domain), `-fakeCalendarAccess` answers the permission without the system alert.
/// Recordings are made with `-resetVoiceRecognition`, so naming a speaker of the fake recording stores no voice that
/// later tests' fake speakers would be recognized as.
final class CalendarTests: ScribeUITestCase {
    /// The event's attendees as EventKit could give them: two people (one "Last, First"), an address, the user, a room,
    /// someone who declined, someone copied in without taking part, and a known person with Exchange's company suffix.
    static let attendees = "Maria Lopez|Berger, Tom|tom@example.com|*Julius Taylor|#Room 4.12|-Paul Declined|~Carla Copied|Schmidt, Anna (Cofinpro)"

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
    /// event; Anna, this speaker's person but not invited, stays on top in Suggestions (below the invitees she was off
    /// the half-height sheet); typing filters the invitees like the people.
    @MainActor
    func testSeededInviteesInRenameSheet() throws {
        let app = launch(["-seedInvitees", "Maria Lopez|Jonas Weber"])
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).waitForExistence(timeout: 5))
        dismissKeyboardTip(app)
        let maria = app.buttons["PersonChoice.Maria Lopez"], jonas = app.buttons["PersonChoice.Jonas Weber"]
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        XCTAssertTrue(jonas.waitForExistence(timeout: 3), "the invitees")
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
        XCTAssertTrue(maria.waitForExistence(timeout: 3), "Maria, the other invitee")
        XCTAssertTrue(maria.label.contains("Invited"), maria.label)
        XCTAssertLessThan(jonas.frame.minY, maria.frame.minY, "by name")
        XCTAssertLessThan(header.frame.minY, jonas.frame.minY)
        XCTAssertTrue(app.staticTexts["From the calendar event “Kickoff Meeting”."].exists, "the footer names the event")
        shot("Seeded invitees, sheet pulled up", app)

        nameField(app).typeText("Ma")
        XCTAssertTrue(maria.waitForExistence(timeout: 3))
        XCTAssertTrue(jonas.waitForNonExistence(timeout: 3), "typing filters the invitees")
        XCTAssertTrue(anna.waitForNonExistence(timeout: 3), "and the suggestions")
        shot("Invitees filtered", app)
        app.buttons["CancelRename"].tap()
    }

    /// Which event names a transcript, one launch per calendar: the one starting closest to the press, also up to
    /// 5 minutes before it starts, not the all-day workshop around it; never an all-day, cancelled or declined one,
    /// nor one starting in 6 minutes, though each would be closer; someone else's event in a calendar shared with the
    /// user read-only never, even when nothing else runs (a partner's "Therapy" naming the user's own memo); the user's
    /// own events first, also in a shared calendar they are invited in, before a closer one they aren't on. (No
    /// apostrophes in the titles: XCUITest's launch arguments mangle them, "Partner's Therapy@…" arrived without its
    /// flags.)
    @MainActor
    func testWhichEventNames() throws {
        let cases: [(calendar: String, name: String?, not: [String])] = [
            ("Workshop@-60+420;Standup@+4+15", "Standup", ["Workshop"]),
            ("Workshop@-60+420;Too Early@+6+30;Offsite@-1+600!allday;Cancelled@-1+30!canceled;Declined@-1+30!declined",
             "Workshop", ["Too Early", "Offsite", "Cancelled", "Declined"]),
            ("Therapy@-1+60!shared", nil, ["Therapy"]),
            ("Therapy@-1+60!shared;Board Meeting@-2+60!others|Anna Schmidt|Tom Berger;Team Sync@-3+30!shared|*Julius Taylor|Maria Lopez",
             "Team Sync", ["Therapy", "Board Meeting"]),
        ]
        for (calendar, name, not) in cases {
            let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", calendar, "-fakeSilence"])
            startRecording(app)
            let expected = name.map { app.staticTexts[$0] }
                ?? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '")).firstMatch
            XCTAssertTrue(expected.waitForExistence(timeout: 10) && waitFor { expected.isHittable },
                          "\(calendar): \(name ?? "New Transcript N")")
            for other in not { XCTAssertFalse(app.staticTexts[other].exists, "\(calendar): not \(other)") }
            shot(name ?? "No event", app)
            app.buttons["Stop"].firstMatch.tap()            // -fakeSilence: nothing saved, the card closes
            XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "the card closes")
        }
    }

    /// A press that resumes a suspended Feder (Control Center, the Action Button, the widget) picks from what was read
    /// before: here "Weekly Sync", which was moved two hours later on another device meanwhile (`-fakeCalendarEventLater`
    /// from 10 s after launch). The read the return starts (3 s, `-fakeCalendarDelay`) ends while the card prepares
    /// (8 s), and the transcript is "New Transcript N" before recording starts. The URL goes through the system
    /// (`XCUIDevice.shared.system.open`): `XCUIApplication.open` relaunches the app, a cold start.
    @MainActor
    func testResumePicksTheEventAgain() throws {
        let app = launch(["-calendarContext", "YES", "-fakeCalendarEvent", "Weekly Sync",
                          "-fakeCalendarEventLater", "Weekly Sync@+120+60", "-fakeCalendarLaterAfter", "10",
                          "-fakeCalendarDelay", "3", "-fakePrepareSeconds", "8", "-fakeSilence"])
        sleep(12)                                           // the launch's read has ended; the calendar has changed
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitFor(timeout: 15) { [.runningBackground, .runningBackgroundSuspended].contains(app.state) },
                      "in the background")
        XCUIDevice.shared.system.open(URL(string: "feder://record")!)
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10), "the card is up")
        let stale = app.staticTexts["Weekly Sync"]
        XCTAssertTrue(stale.exists, "the press picked from the cache read before the change")
        XCTAssertFalse(app.staticTexts["Listening…"].exists || app.buttons["Stop"].exists, "still preparing")
        shot("Preparing, picked from the old read", app)
        XCTAssertTrue(app.staticTexts["Listening…"].waitForExistence(timeout: 30), "then recording")
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '"))
        XCTAssertTrue(title.allElementsBoundByIndex.contains { $0.isHittable }, "named again from the new read")
        XCTAssertFalse(stale.exists, "not the moved meeting")
        shot("Recording, the moved meeting gone", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "the card closes")
    }

    /// Name from Calendar turned off while recording (the card minimized, Settings, back): the transcript keeps the
    /// name it showed, but no invitees are saved with it, as Save Location keeps no place then: its rename sheet has no
    /// Invitees. `-calendarOn` (stored, so the switch can turn it off) and off again at the end.
    @MainActor
    func testSwitchedOffBeforeStopSavesNoInvitees() throws {
        let app = launch(["-calendarOn", "-fakeCalendarEvent", "Design Review|Maria Lopez|Berger, Tom",
                          "-fakeGemma", "-resetVoiceRecognition"])
        startRecording(app)
        XCTAssertTrue(app.staticTexts["Design Review"].waitForExistence(timeout: 5), "the card is named after the event")
        app.buttons["Minimize"].tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "on")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (toggle.value as? String) == "0" }, "off")
        app.buttons["Recording"].firstMatch.tap()           // back to the card from the accessory
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 5))
        sleep(6)                                            // two speakers: FakeDiarizer changes every 4 s
        app.buttons["Stop"].firstMatch.tap()

        let field = app.textFields["Title"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the transcript in the card")
        XCTAssertEqual(field.value as? String, "Design Review", "the name stays as shown")
        // Names can be changed once the speakers are final; the summary comes after that.
        XCTAssertTrue(app.buttons["Summary"].waitForExistence(timeout: 40), "the speakers are final")
        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(nameField(app).waitForExistence(timeout: 5), "the rename sheet")
        dismissKeyboardTip(app)
        XCTAssertFalse(app.staticTexts["Invitees"].exists, "no invitees saved")
        XCTAssertFalse(app.buttons["PersonChoice.Maria Lopez"].exists)
        shot("No invitees after turning it off", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).waitForNonExistence(timeout: 5))
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "the card closes")
    }

    /// Settings' switch asks for access (answered by `-fakeCalendarAccess granted`, no system alert) and turns on;
    /// off again for the next tests.
    @MainActor
    func testSwitchTurnsOn() throws {
        let app = launch(["-resetCalendar", "-fakeCalendarAccess", "granted"])
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
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
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let alert = app.alerts["Allow Calendar Access"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "it offers the iPhone's Settings")
        alert.buttons["Open Settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "the Settings app")
        app.activate()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(timeout: 10) { (toggle.value as? String) == "1" }, "on when back with access given")
        shot("Back from Settings: on", app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { (toggle.value as? String) == "0" }, "off again")
    }

    /// Settings' Preferred Calendar (the fake's calendars: iCloud's Home and Work, Exchange's Calendar): below the switch
    /// while it is on, None by default. Its page lists None, then the calendars by account; Work chosen there names the
    /// transcript after "Planning" in Work, though "Standup" in Home started closer to the press (without a preference
    /// Standup names it: testWhichEventNames). None again at the end.
    @MainActor
    func testPreferredCalendarWins() throws {
        let app = launch(["-resetCalendar", "-calendarContext", "YES",
                          "-fakeCalendarEvent", "Planning@-30+90!cal=Work;Standup@-1+15", "-fakeSilence"])
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Name from Calendar"].firstMatch
        let row = preferredRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "below the switch while it is on")
        XCTAssertTrue(shown(row).contains("None"), "None by default: \(shown(row))")
        XCTAssertLessThanOrEqual(toggle.frame.maxY, row.frame.minY + 1, "below Name from Calendar")
        XCTAssertLessThanOrEqual(row.frame.maxY, app.switches["Save Location"].firstMatch.frame.minY + 1, "above Save Location")
        row.tap()

        XCTAssertTrue(app.navigationBars["Preferred Calendar"].waitForExistence(timeout: 5), "its own page")
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
        note("Preferred Calendar tree", app.debugDescription)
        work.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back in Settings")
        XCTAssertTrue(waitFor { self.shown(row).contains("Work") }, "Work chosen: \(shown(row))")
        shot("Preferred Calendar: Work", app)

        startRecording(app)
        XCTAssertTrue(app.staticTexts["Planning"].waitForExistence(timeout: 10) && waitFor { app.staticTexts["Planning"].isHittable },
                      "the event in the preferred calendar")
        XCTAssertFalse(app.staticTexts["Standup"].exists, "not the closer one in Home")
        shot("Named after the preferred calendar's event", app)
        app.buttons["Stop"].firstMatch.tap()                // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "the card closes")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        XCTAssertTrue(work.isSelected, "Work checked")
        none.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { self.shown(row).contains("None") }, "None again: \(shown(row))")
    }

    /// The preferred calendar's identifier changed since it was chosen (`-fakeCalendarResynced`: a full sync; Apple says
    /// identifiers can change then): it is found again by its name and account, and its event still wins. A preferred
    /// calendar that is gone counts as None: the closer Standup names it, and Settings says None.
    @MainActor
    func testPreferredCalendarAfterResync() throws {
        let events = "Planning@-30+90!cal=Work;Standup@-1+15"
        for (preferred, name) in [("Work", "Planning"), ("Gone", "Standup")] {
            let app = launch(["-resetCalendar", "-calendarContext", "YES", "-preferFakeCalendar", preferred,
                              "-fakeCalendarResynced", "YES", "-fakeCalendarEvent", events, "-fakeSilence"])
            startRecording(app)
            let title = app.staticTexts[name]
            XCTAssertTrue(title.waitForExistence(timeout: 10) && waitFor { title.isHittable }, "\(preferred): \(name)")
            app.buttons["Stop"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10), "the card closes")
            app.buttons["Settings"].firstMatch.tap()
            let row = preferredRow(app)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(shown(row).contains(preferred == "Gone" ? "None" : "Work"), "\(preferred): \(shown(row))")
            shot("Preferred \(preferred) after a resync", app)
        }
    }

    /// Settings' Preferred Calendar row (a navigation-link picker: a button labelled with its name, the choice its value).
    private func preferredRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preferred Calendar'")).firstMatch
    }

    private func shown(_ row: XCUIElement) -> String {
        "\(row.label) \(row.value as? String ?? "")"
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
