import XCTest

/// The Transcripts list: the scrolling headings, Voice Memos-style swipe actions (wide pills, title under them), the
/// record accessory's flow and the transcript card (opened from a row or out of the accessory, closed by its back
/// button or a swipe to the right; its bottom toolbar).
final class TranscriptListTests: ScribeUITestCase {

    /// The "Transcripts" and "Settings" headings are not pinned in a navigation bar: they are the first row (section
    /// header) and scroll away with the content. Neither has a navigation bar: Transcripts' Import sits on its heading's
    /// line, at the right (FED-134). `-seedFiller 12` makes the list long enough to scroll. The Search tab has no
    /// heading: its bar is at the top.
    @MainActor
    func testHeadingsScrollAway() throws {
        let app = launch(["-seedFiller", "12"])
        let heading = app.collectionViews.staticTexts["Transcripts"]   // not the tab
        XCTAssertTrue(heading.appears(timeout: 5), "the Transcripts heading")
        let importButton = app.buttons["ImportAudio"]
        XCTAssertLessThan(abs(heading.frame.midY - importButton.frame.midY), 4, "Import on the heading's line: \(heading.frame) \(importButton.frame)")
        XCTAssertGreaterThan(importButton.frame.minX, app.frame.width * 0.7, "at the right: \(importButton.frame)")
        XCTAssertLessThan(heading.frame.minY, 100, "at the top at rest: \(heading.frame)")
        XCTAssertLessThan(heading.frame.maxY, app.cells.containing(.staticText, identifier: "Project Kickoff").firstMatch.frame.minY + 1,
                          "above the first transcript")
        XCTAssertFalse(app.navigationBars.staticTexts["Transcripts"].exists, "no navigation bar title")
        let transcriptsTop = heading.frame.minY
        shot("List at rest", app)
        app.swipeUp()
        XCTAssertTrue(scrolledAway(heading, app), "the heading scrolls away with the list: \(heading.frame)")
        shot("List scrolled", app)

        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5))
        dismissKeyboardTip(app)
        let suggested = app.staticTexts["Suggested"]
        XCTAssertTrue(suggested.appears(timeout: 5))
        XCTAssertGreaterThan(suggested.frame.minY, app.textFields["SearchField"].frame.maxY, "content under the bar")
        XCTAssertLessThan(suggested.frame.minY, 200, "right under it: \(suggested.frame)")
        XCTAssertFalse(app.collectionViews.staticTexts["Search"].exists, "no Search heading")
        shot("Searching", app)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.textFields["SearchField"].disappears(timeout: 5), "back from search")

        app.buttons["Settings"].firstMatch.tap()
        let settings = app.collectionViews.staticTexts["Settings"]
        XCTAssertTrue(app.switches["Live Speaker Labels"].appears(timeout: 5))
        XCTAssertTrue(settings.exists, "the Settings heading")
        XCTAssertLessThan(abs(settings.frame.minY - transcriptsTop), 3, "where Transcripts' heading is: \(settings.frame) \(transcriptsTop)")
        XCTAssertFalse(app.navigationBars.staticTexts["Settings"].exists, "no navigation bar title")
        shot("Settings at rest", app)
        // Since the Recording sections were merged (October 2026) the form fits an iPhone 17 Pro's screen at the
        // default text size and doesn't scroll at all. At a large text size it does, and the heading must move with it
        // (a navigation bar title would stay).
        app.terminate()
        let large = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
        large.buttons["Settings"].firstMatch.tap()
        let largeHeading = large.collectionViews.staticTexts["Settings"]
        XCTAssertTrue(largeHeading.appears(timeout: 5), "the Settings heading at a large text size")
        let rest = largeHeading.frame
        large.swipeUp()
        XCTAssertTrue(scrolledAway(largeHeading, large) || largeHeading.frame.minY < rest.minY - 30,
                      "the heading scrolls with the form: \(rest) -> \(largeHeading.frame)")
        shot("Settings scrolled, large text", large)
    }

    /// Two voices are "Speaker 1" and "Speaker 2" on the live screen, also when the live diarizer puts the second one in
    /// its third slot (`-fakeLiveSkipSlot`, as LS-EEND sometimes does): numbered by first appearance (FED-108).
    @MainActor
    func testLiveSpeakersNumberedInOrder() throws {
        let app = launch(["-fakeLiveSkipSlot", "YES", "-resetVoiceRecognition"])
        startRecording(app)
        let live = { (n: Int) in app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Speaker \(n): ")).firstMatch }
        XCTAssertTrue(live(1).appears(timeout: 15), "the first voice")
        XCTAssertTrue(live(2).appears(timeout: 15), "the second voice is Speaker 2")
        XCTAssertFalse(live(3).exists, "no Speaker 3 for two voices")
        shot("Live: Speaker 1 and 2", app)
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Title"].appears(timeout: 15), "saved")
        deleteOpenTranscript(app)
    }

    /// Gone, or above the top safe area (under the status bar), once the scroll settles.
    @MainActor
    private func scrolledAway(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        let end = Date.now.addingTimeInterval(3)
        while Date.now < end {
            if !element.exists || element.frame.maxY < 60 { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return false
    }

    /// Swiping a row left shows Share and Delete (outermost); Delete removes it.
    @MainActor
    func testSwipeShowsShareAndDelete() throws {
        let app = launch()
        let row = app.cells.containing(.staticText, identifier: "Budget Review").firstMatch
        XCTAssertTrue(row.appears(timeout: 5))
        row.swipeLeft()
        let delete = app.buttons["Delete"], share = app.buttons["Share"]
        XCTAssertTrue(delete.appears(timeout: 3), "Delete")
        XCTAssertTrue(share.exists, "Share")
        XCTAssertGreaterThan(delete.frame.minX, share.frame.minX, "Delete outermost")
        shot("Swiped", app)
        delete.tap()
        XCTAssertTrue(app.staticTexts["Budget Review"].disappears(timeout: 5), "deleted")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists)
    }

    /// Voice Memos' look, with and without tags: iOS draws wide pills with the title under them only for rows about
    /// 62-70 pt tall (shorter: capsules with the title inside; from 76 pt: round buttons), so every row is two lines
    /// (tags on the date line) and at least 62 pt, Voice Memos' height, whose pills are about 60 × 33 pt. As in Voice
    /// Memos, the separators start at the text (FED-74).
    @MainActor
    func testSwipePillsOnRowsWithAndWithoutTags() throws {
        let app = launch(["-seedPendingSample", "-fakeDiarizeSeconds", "60"])
        for title in ["Weekly Sync", "Project Kickoff"] {                   // no tags; two tags
            let row = app.cells.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(row.appears(timeout: 5))
            assertSeparatorStartsAtText(under: title, app)
            XCTAssertEqual(row.frame.height, 62, accuracy: 3, "\(title): a two-line row like Voice Memos': \(row.frame)")
            row.swipeLeft()
            let delete = app.buttons["Delete"]
            XCTAssertTrue(delete.appears(timeout: 3))
            shot("Swiped \(title)", app)
            note("Swipe \(title)", "row \(row.frame), Delete \(delete.frame), Share \(app.buttons["Share"].frame)")
            XCTAssertGreaterThan(delete.frame.width, delete.frame.height + 10, "\(title): a wide pill: \(delete.frame)")
            XCTAssertEqual(delete.frame.height, 34, accuracy: 3, "\(title): Voice Memos' pill height: \(delete.frame)")
            XCTAssertTrue(app.staticTexts["Delete"].exists || delete.label == "Delete", "the title")
            row.swipeRight()                                                 // closes it
            XCTAssertTrue(delete.disappears(timeout: 3))
        }
    }

    /// Recording like Music's "Now Playing": Transcribe (the accessory) opens the transcript card with the live view and
    /// a large Stop; at its top, like Voice Memos' recording sheet, the name the transcript will get ("New Transcript
    /// N") and its date line with the start time, where the transcript has them. Minimize (the back button) shrinks it back
    /// into the accessory, which shows "Recording" and Stop while the list can be browsed; a tap on the accessory opens
    /// it again; Stop saves it and the SAME card turns into the transcript in place (no push, no Back): the same title
    /// and date line at the same place, the timer landed as the duration beside the date, and the bottom toolbar where
    /// the Stop was, one Share, Find, More and Delete each (the melt's stand-ins are gone). Minimize then closes
    /// it to the list, where the new transcript is at the top with the start time.
    @MainActor
    func testRecordAccessoryFlow() throws {
        let app = launch()
        let record = transcribe(app)
        XCTAssertTrue(record.appears(timeout: 5), "the accessory says Transcribe")
        let tapped = Date.now
        startRecording(app)
        let bigStop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(bigStop.appears(timeout: 10), "a large Stop")
        XCTAssertGreaterThanOrEqual(bigStop.frame.width, 70, "large: \(bigStop.frame)")
        XCTAssertTrue(app.buttons["Minimize"].exists, "the back button")
        XCTAssertFalse(isOnScreen(app.buttons["Settings"].firstMatch, app), "full screen, like Now Playing")

        // The transcript's header already: its name and the start time (not the time of Stop) under it.
        let title = reachable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '")))
        XCTAssertNotNil(title, "the name the transcript will get")
        let date = reachable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today at '")))
        XCTAssertNotNil(date, "the date line")
        guard let title, let date else { return }
        let name = title.label, day = date.label
        let titleFrame = title.frame, dateFrame = date.frame
        XCTAssertTrue(startTexts(from: tapped).contains(day), "the start time: \(day), tapped at \(tapped)")
        XCTAssertLessThan(titleFrame.minY, 140, "at the top, under the back button: \(titleFrame)")
        XCTAssertLessThanOrEqual(titleFrame.maxY, dateFrame.minY + 1, "the date line under the title: \(dateFrame)")
        XCTAssertEqual(titleFrame.minX, dateFrame.minX, accuracy: 1, "one leading margin")
        XCTAssertLessThan(dateFrame.maxY, bigStop.frame.minY, "the Stop at the bottom")
        note("Recording header", "title \(name) \(titleFrame), date \(day) \(dateFrame), Stop \(bigStop.frame)")
        shot("Recording", app)

        app.buttons["Minimize"].tap()                                       // back into the accessory, still recording
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card closed")
        XCTAssertTrue(app.cells.firstMatch.appears(timeout: 5))
        let accessory = app.buttons["Recording"].firstMatch
        XCTAssertTrue(accessory.appears(timeout: 5), "the accessory shows the recording")
        let accessoryStop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(accessoryStop.exists, "with Stop")
        XCTAssertLessThan(accessoryStop.frame.width, 70, "the accessory's small Stop: \(accessoryStop.frame)")
        XCTAssertTrue(app.cells.firstMatch.isHittable, "browsing the list meanwhile")
        shot("Recording minimized", app)

        accessory.tap()                                                     // opens it again
        XCTAssertTrue(app.buttons["Minimize"].appears(timeout: 5), "the card again")
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertGreaterThanOrEqual(stop.frame.width, 70, "the card's large Stop: \(stop.frame)")
        XCTAssertFalse(app.staticTexts["Listening…"].exists, "words were transcribed (or Stop discards it)")
        stop.tap()

        // The same card turns into the transcript with the name it showed. Read at once: the automatic title (after
        // speaker identification) may replace it a few seconds later.
        let field = app.textFields["Title"]
        XCTAssertTrue(field.appears(timeout: 15), "the transcript in the card")
        XCTAssertEqual(field.value as? String, name, "saved with the name the recording showed")
        // Its bottom toolbar replaces the Stop (shown once the turn is over), the back button stays.
        XCTAssertTrue(app.buttons["Share Transcript"].appears(timeout: 15), "the transcript's toolbar")
        assertCard(app)
        XCTAssertFalse(app.buttons["Stop"].exists, "the Stop gave way to the toolbar")
        XCTAssertFalse(app.staticTexts["Recording"].exists, "the recording's timer is gone")
        XCTAssertNil(reachable(app.staticTexts.matching(NSPredicate(format: "label == %@", name)), timeout: 0),
                     "only the transcript's title field shows the name (the recording's header is gone)")
        // One of each, hittable: the melt's glass stand-ins are gone and were never in the accessibility tree.
        for label in ["Share Transcript", "Find in Transcript", "More", "Delete Transcript"] {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertEqual(matches.count, 1, "exactly one \(label)")
            XCTAssertTrue(matches.firstMatch.isHittable && matches.firstMatch.isEnabled, "\(label) can be tapped")
        }
        // This simulator can't run Gemma (no -fakeGemma): no Action Items, the melt's layout without it.
        XCTAssertFalse(app.buttons["Action Items"].exists, "no Action Items without Gemma")
        // Title and date line where the recording had them; the timer is now the duration beside the date.
        let savedDate = reachable(app.staticTexts.matching(NSPredicate(format: "label == %@", day)), timeout: 5)
        XCTAssertNotNil(savedDate, "the transcript's date line has the start time \(day)")
        let duration = savedDate.flatMap { date in        // "0:12" on the date's line (not a turn's time further down)
            app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+:[0-9][0-9]'")).allElementsBoundByIndex
                .first { abs($0.frame.midY - date.frame.midY) < 4 && $0.isHittable }
        }
        XCTAssertNotNil(duration, "the duration in the date line")
        if let savedDate, let duration {
            note("Transcript header", "title \(field.frame), date \(savedDate.frame), duration \(duration.label) "
                 + "\(duration.frame); recording's: title \(titleFrame), date \(dateFrame)")
            XCTAssertEqual(savedDate.frame.minX, dateFrame.minX, accuracy: 1, "the date stays put: \(savedDate.frame)")
            XCTAssertEqual(savedDate.frame.minY, dateFrame.minY, accuracy: 1, "the date stays put: \(savedDate.frame)")
            XCTAssertEqual(field.frame.minX, titleFrame.minX, accuracy: 1, "the title stays put: \(field.frame)")
            XCTAssertEqual(field.frame.midY, titleFrame.midY, accuracy: 1, "the title stays put: \(field.frame)")
            XCTAssertGreaterThan(duration.frame.minX, savedDate.frame.maxX, "the duration after the date")
            XCTAssertEqual(duration.frame.midY, savedDate.frame.midY, accuracy: 2, "on the date's line")
        }
        shot("After Stop", app)

        closeCard(app)
        XCTAssertTrue(record.appears(timeout: 5), "the accessory is back to Transcribe")
        XCTAssertTrue(record.isHittable)
        // The new transcript tops the list, above Project Kickoff (seeded at launch, the newest until now), with the
        // start time. Its title may already be the automatic one, so it is found by its place, not by its name.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Today at '"))
        XCTAssertTrue(rows.firstMatch.appears(timeout: 5))
        let newest = rows.element(boundBy: 0), kickoff = app.staticTexts["Project Kickoff"].firstMatch
        XCTAssertFalse(newest.label.hasPrefix("Project Kickoff"), "the new transcript is at the top: \(newest.label)")
        XCTAssertTrue(newest.label.contains(", \(day), "), "listed with the start time \(day): \(newest.label)")
        XCTAssertLessThan(newest.frame.minY, kickoff.frame.minY, "above Project Kickoff")
        shot("Back in the list", app)

        // Opened again from its row, then deleted, so recordings of earlier runs don't pile up in the simulator's
        // store (the tests only replace the seeded transcripts).
        newest.tap()
        assertCard(app)
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card closes")
        XCTAssertTrue(kickoff.appears(timeout: 5))
        let top = rows.element(boundBy: 0)
        for _ in 0..<25 where !top.label.hasPrefix("Project Kickoff") { RunLoop.current.run(until: .now + 0.2) }
        XCTAssertTrue(top.label.hasPrefix("Project Kickoff"), "deleted: Project Kickoff tops the list again: \(top.label)")
    }

    /// Stop with nothing transcribed (`-fakeSilence`: the simulator's fake transcriber hears nothing) saves nothing:
    /// the card shows the name and start time while recording, as always, but Stop closes it straight back to the
    /// list, with no transcript (no turn, no toolbar), and the accessory says Transcribe again.
    @MainActor
    func testStopWithNothingTranscribedClosesCard() throws {
        let app = launch(["-fakeSilence"])
        let record = transcribe(app)
        XCTAssertTrue(record.appears(timeout: 5), "the accessory says Transcribe")
        let tapped = Date.now
        startRecording(app)
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.appears(timeout: 10), "the large Stop")
        XCTAssertNotNil(reachable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript '"))),
                        "the name the transcript would get")
        let date = reachable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today at '")))
        XCTAssertTrue(date.map { startTexts(from: tapped).contains($0.label) } ?? false, "the start time: \(String(describing: date?.label))")
        RunLoop.current.run(until: .now + 1.5)                              // the canned words would be there by now
        XCTAssertTrue(app.staticTexts["Listening…"].exists, "nothing heard")
        shot("Recording silence", app)
        stop.tap()

        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 10), "the card closes")
        XCTAssertFalse(app.buttons["Share Transcript"].exists, "no transcript")
        XCTAssertFalse(app.textFields["Title"].exists, "no transcript")
        XCTAssertTrue(record.appears(timeout: 5) && record.isHittable, "the accessory is back to Transcribe")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Today at '"))
        XCTAssertTrue(rows.firstMatch.appears(timeout: 5))
        XCTAssertTrue(rows.element(boundBy: 0).label.hasPrefix("Project Kickoff"),
                      "nothing saved: Project Kickoff still tops the list: \(rows.element(boundBy: 0).label)")
        shot("After Stop, nothing saved", app)
    }

    /// The first of `query`'s elements that is on screen and not covered (the list under the card stays in the tree,
    /// covered), waiting up to `timeout`.
    @MainActor
    private func reachable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let end = Date.now.addingTimeInterval(timeout)
        repeat {
            if let element = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return element }
            if timeout > 0 { RunLoop.current.run(until: .now + 0.2) }
        } while Date.now < end
        return nil
    }

    /// The date line of a recording started just after `tapped` ("Today at 14:02", the app's `relativeDayText`: the
    /// time in English with the region's 12/24-hour clock), in that minute or the next.
    private func startTexts(from tapped: Date) -> [String] {
        let locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
        return [0, 60].map { "Today at " + tapped.addingTimeInterval($0).formatted(.dateTime.hour().minute().locale(locale)) }
    }

    /// A tap on a row opens the transcript card (zooming out of the row; no push): the back button at the top left, the
    /// bottom toolbar, no navigation bar. The back button closes it back to the list, and so does swiping the card to
    /// the right from the left edge; swiping it down does not (that only scrolls).
    @MainActor
    func testRowOpensCardAndBackOrSwipeRightClosesIt() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        shot("Card", app)
        // Project Kickoff runs on under the bottom toolbar: there, between the Share…More group and Delete, the text
        // is faded by the system's soft scroll edge (as in Notes and Mail), not crisp next to the glass.
        let more = app.buttons["More"].frame, delete = app.buttons["Delete Transcript"].frame
        let gap = CGRect(x: more.maxX + 12, y: more.midY - 12, width: delete.minX - more.maxX - 24, height: 24)
        let crisp = crispShare(of: gap, in: app)
        note("Under the toolbar", "crisp share \(crisp) in \(gap)")
        XCTAssertLessThan(crisp, 0.002, "text under the bottom toolbar is faded (scroll edge effect): \(crisp)")
        note("Under the card", "list cells in the tree: \(app.cells.count), Transcribe exists \(transcribe(app).exists) "
             + "hittable \(transcribe(app).exists && transcribe(app).isHittable), tab bars \(app.tabBars.count)")
        closeCard(app)
        XCTAssertTrue(app.cells.firstMatch.isHittable, "back in the list")
        XCTAssertTrue(transcribe(app).appears(timeout: 5) && transcribe(app).isHittable, "with the accessory")

        open("Project Kickoff", in: app)                                    // (on a simulator with many transcripts
        let back = app.buttons["Minimize"]                                  // Budget Review is below the screen)
        // Swiping down (from the text, and from the top where the grabber used to be) leaves the card up.
        for dy in [0.5, 0.12] {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 450)),
                        withVelocity: .fast, thenHoldForDuration: 0)
            RunLoop.current.run(until: .now + 1)
            XCTAssertTrue(back.exists && app.textFields["Title"].exists, "swiping down doesn't close the card")
        }
        shot("Swiped down, still up", app)
        // A short swipe to the right springs back and leaves the card up. While it is held the list shows beside the
        // card, not the window's empty background (FED-136; seen in a recording of this test, XCUITest can't look
        // while the finger is down).
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)), withVelocity: .slow,
                   thenHoldForDuration: 1.5)
        RunLoop.current.run(until: .now + 1)
        XCTAssertTrue(back.exists && back.isHittable, "a short swipe springs back")
        swipeCardRight(app)
        XCTAssertTrue(back.disappears(timeout: 5), "swiping right closes the card")
        XCTAssertTrue(app.cells.firstMatch.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists, "still listed")
        XCTAssertTrue(transcribe(app).isHittable, "the accessory is back")
        shot("Swiped right", app)
    }

    /// Swiping right closes the recording card too (back into the accessory, recording goes on), and in a long
    /// transcript swiping down and up scrolls it, keeping the card up; a swipe right then closes it.
    @MainActor
    func testSwipeRightClosesRecordingAndLongTranscriptScrolls() throws {
        let app = launch(["-fakeBacklogMinutes", "3"])                      // a transcript long enough to scroll
        startRecording(app)
        XCTAssertTrue(app.buttons["Stop"].firstMatch.appears(timeout: 10))
        swipeCardRight(app)
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "swiping right closes the recording card")
        let accessory = app.buttons["Recording"].firstMatch
        XCTAssertTrue(accessory.appears(timeout: 5), "recording goes on in the accessory")
        accessory.tap()
        XCTAssertTrue(app.buttons["Minimize"].appears(timeout: 5))
        app.buttons["Stop"].firstMatch.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.appears(timeout: 15), "the transcript in the card")
        XCTAssertTrue(app.buttons["Share Transcript"].appears(timeout: 15))
        RunLoop.current.run(until: .now + 1)
        app.swipeUp()                                                       // scrolls the transcript: the title goes
        XCTAssertTrue(waitFor { !(title.exists && title.isHittable) }, "swiping up scrolls the transcript")
        XCTAssertTrue(app.buttons["Minimize"].exists, "the card is still up")
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(waitFor { title.exists && title.isHittable }, "swiping down scrolls back up")
        XCTAssertTrue(app.buttons["Minimize"].exists, "swiping down doesn't close the card")
        shot("Scrolled back", app)
        swipeCardRight(app)
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "swiping right closes the transcript")
        // Delete the recording, so test recordings don't pile up in the simulator's store.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Today at '"))
        XCTAssertTrue(rows.firstMatch.appears(timeout: 5))
        rows.element(boundBy: 0).tap()
        assertCard(app)
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5))
    }


    /// The card's actions are in the system's bottom toolbar (like Photos and Mail; Liquid Glass), not in a top menu:
    /// Share, Find, More (Add Tag, Edit Text) and Delete, within thumb reach; the card covers the tab bar and the record
    /// accessory. No Action
    /// Items on this simulator, which can't run Gemma (ActionItemsTests pretend it can), and no Speakers menu. Delete asks
    /// first, then the card closes and the transcript is gone from the list.
    @MainActor
    func testCardBottomToolbar() throws {
        let app = launch()
        open("Budget Review", in: app)
        let share = app.buttons["Share Transcript"]
        let find = app.buttons["FindButton"], more = app.buttons["More"], delete = app.buttons["Delete Transcript"]
        let height = app.windows.firstMatch.frame.height
        for (element, name) in [(share, "Share"), (find, "Find"), (more, "More"), (delete, "Delete")] {
            XCTAssertTrue(element.appears(timeout: 5), name)
            XCTAssertTrue(element.isHittable, "\(name) is not hidden in an overflow menu")
            XCTAssertGreaterThan(element.frame.minY, height * 0.85, "\(name) at the bottom")
        }
        XCTAssertLessThan(share.frame.minX, find.frame.minX, "Find beside Share, in the left group")
        XCTAssertLessThan(find.frame.minX, more.frame.minX, "More last in the group")
        XCTAssertLessThan(more.frame.maxX, delete.frame.minX, "Delete on the right")
        XCTAssertGreaterThan(more.frame.minY, height * 0.85, "More in the bottom bar, not a top-right menu")
        more.tap()                                                          // Add Tag and Edit Text in it
        for label in ["Add Tag", "Edit Text"] {
            XCTAssertTrue(app.buttons[label].appears(timeout: 5), "\(label) in More")
        }
        shot("Card toolbar's More menu", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
        XCTAssertTrue(app.buttons["Add Tag"].disappears(timeout: 5), "the menu closed")
        shot("Card toolbar", app)

        XCTAssertFalse(app.buttons["Action Items"].exists, "no Action Items without Gemma, though items are stored")
        XCTAssertFalse(app.buttons["Speakers"].exists, "no speaker-count menu")

        let trash = delete.frame                                            // the dialog grows out of it, replacing it
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5), "asks first")
        shot("Delete confirmation", app)
        note("Delete confirmation", "confirm \(confirm.frame), trash \(trash)")
        // It comes out of the trash button (like Photos and Notes): on its side of the card, not floating mid-card.
        XCTAssertGreaterThan(confirm.frame.midX, app.windows.firstMatch.frame.midX,
                             "anchored to Delete on the right: \(confirm.frame)")
        XCTAssertGreaterThan(confirm.frame.maxX, trash.midX, "reaching to the trash button: \(confirm.frame) \(trash)")
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card closes")
        XCTAssertTrue(transcribe(app).appears(timeout: 5), "back in the list, with the accessory")
        XCTAssertTrue(app.staticTexts["Budget Review"].disappears(timeout: 5), "deleted")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists)
    }

    /// Share opens the share sheet with the transcript.
    @MainActor
    func testSwipeShare() throws {
        let app = launch()
        let row = app.cells.containing(.staticText, identifier: "Project Kickoff").firstMatch
        XCTAssertTrue(row.appears(timeout: 5))
        row.swipeLeft()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.appears(timeout: 3))
        XCTAssertTrue(waitFor { share.isHittable }, "the pill has slid in")
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(waitFor(timeout: 10) { sheet.exists || app.navigationBars["UIActivityContentView"].exists },
                      "the share sheet")
        shot("Share sheet", app)
    }
}
