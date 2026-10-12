import XCTest

/// Action items (ActionItemExtractor, the card's "Action Items" row under Summary): folded until tapped, added to
/// Reminders (EventKit, full access asked at the first add; what arrived there is read back and removed with
/// `-federRemindersReport`) and Calendar (Apple's New Event editor), removed and put back (Undo); found by the pipeline
/// after Stop (`-fakeGemma`: FakeTextWriter answers with two items, one due on a day, one at a time); a transcript's
/// link from Reminders (feder://transcript/<id>) opens its card. "Budget Review" is seeded with two items: "Send the
/// numbers to finance" (Anna Schmidt, by Friday) and "Add the third-quarter forecast" (Anna Schmidt).
final class ActionItemsTests: ScribeUITestCase {
    static let budgetLink = "feder://transcript/5C0FFEE0-0000-4000-8000-000000000002"
    /// An item's row: the task with who and when under it, one accessibility element.
    @MainActor
    private func item(_ index: Int, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["ActionItem.\(index)"].firstMatch
    }

    @MainActor
    private func openBudgetItems(_ app: XCUIApplication) -> XCUIElement {
        open("Budget Review", in: app)
        let row = app.buttons["ActionItems"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Action Items row")
        row.tap()
        XCTAssertTrue(item(0, app).waitForExistence(timeout: 3), "a tap shows the items")
        return row
    }

    /// Chooses `choice` in item `index`'s menu.
    @MainActor
    private func choose(_ choice: String, forItem index: Int, _ app: XCUIApplication) {
        let menu = app.buttons["ActionItemMenu.\(index)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "the item's menu")
        menu.tap()
        let button = app.buttons[choice].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "\(choice) in the menu")
        button.tap()
    }

    /// What reached the simulator's Reminders: the app relaunched with `-federRemindersReport` (without seeding or
    /// recording) shows Feder's reminders in an alert, one line each, "title | due | alarms | link | notes", and removes
    /// them, so test runs don't pile up there. "no access" without full access.
    @MainActor
    private func takeReminders(_ app: XCUIApplication) -> [String] {
        app.terminate()
        var arguments: [String] = []
        var skipValue = false
        for argument in app.launchArguments {
            if skipValue { skipValue = false; continue }
            if argument == "-autoStopAfter" { skipValue = true; continue }
            if ["-seedSamples", "-autoRecord", "-fakeGemma", "-federRemindersReport"].contains(argument) { continue }
            arguments.append(argument)
        }
        app.launchArguments = arguments + ["-federRemindersReport"]
        app.launch()
        let alert = app.alerts["Feder Reminders"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "the report")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).first { $0 != "Feder Reminders" } ?? ""
        note("Feder's reminders", message)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        return message.split(separator: "\n").map(String.init)
    }

    /// The next `weekday` (Sunday = 1) strictly after `day`, as "yyyy-MM-dd" (DueDate's rule for "by Friday").
    private func next(_ weekday: Int, after day: Date) -> String {
        let calendar = Calendar.current
        var ahead = (weekday - calendar.component(.weekday, from: day) + 7) % 7
        if ahead == 0 { ahead = 7 }
        return Self.ymd(calendar.date(byAdding: .day, value: ahead, to: calendar.startOfDay(for: day))!)
    }

    private static func ymd(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// iOS's question for Reminders (springboard): allows full access, or doesn't. Springboard speaks the simulator's
    /// language, not the app's `-AppleLanguages (en)`: "Allow Full Access" / "Don't Allow", or the German labels.
    @MainActor
    private func answerRemindersAlert(allow: Bool) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 15) else { return false }
        note("Reminders alert", alert.debugDescription)
        screenShot(allow ? "Reminders question" : "Reminders question (denied)")
        let denies = "(label BEGINSWITH[c] 'don' OR label BEGINSWITH[c] 'nicht')"
        let predicate = allow
            ? NSPredicate(format: "(label CONTAINS[c] 'allow' OR label CONTAINS[c] 'erlauben') AND NOT \(denies)")
            : NSPredicate(format: denies)
        let button = alert.buttons.matching(predicate).firstMatch
        guard button.exists else { return false }
        button.tap()
        return true
    }

    /// Budget Review's row under Summary, folded: its value names the two items; a tap shows them with who and when
    /// (the first one's due date is a Friday), the transcript moves down, another tap folds it.
    @MainActor
    func testActionItemsFoldedUntilTapped() throws {
        let app = launch()
        open("Budget Review", in: app)
        let row = app.buttons["ActionItems"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Action Items row")
        let value = row.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("2"), "VoiceOver: the count first: \(value)")
        XCTAssertTrue(value.contains("Send the numbers to finance"), "and the tasks: \(value)")
        let summary = app.buttons["Summary"]
        XCTAssertGreaterThanOrEqual(row.frame.minY, summary.frame.maxY - 1, "under Summary: \(row.frame), \(summary.frame)")
        XCTAssertLessThan(row.frame.minY, app.staticTexts["AINotice"].frame.minY, "above the AI note")
        XCTAssertGreaterThan(row.frame.width, 300, "the whole width is the target")
        XCTAssertFalse(item(0, app).exists, "folded: no items shown")
        let firstName = app.buttons["SpeakerHeader.0"].frame.minY
        shot("Action items folded", app)

        row.tap()
        let first = item(0, app)
        XCTAssertTrue(first.waitForExistence(timeout: 3), "a tap shows them")
        XCTAssertTrue(first.label.contains("Send the numbers to finance"), first.label)
        XCTAssertTrue(first.label.contains("Anna Schmidt"), "who: \(first.label)")
        XCTAssertTrue(first.label.contains("Fri"), "by Friday, as a date: \(first.label)")
        XCTAssertTrue(item(1, app).label.contains("Add the third-quarter forecast"), item(1, app).label)
        XCTAssertTrue(app.buttons["AddAllToReminders"].exists, "Add All while two aren't in Reminders")
        sleep(1)
        XCTAssertGreaterThan(app.buttons["SpeakerHeader.0"].frame.minY, firstName + 60, "the transcript moves down")
        shot("Action items open", app)

        row.tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 3), "another tap folds it again")
    }

    /// Add to Reminders asks for full access the first time (iOS's alert), then the item says "In Reminders" and its
    /// menu's plus turns into a checkmark (VoiceOver: its value); the menu then offers "Add to Reminders Again". In
    /// Reminders: the task, due all day on the Friday after the meeting (no time said: no alarm), the transcript's link
    /// and who and where from in the notes. After a relaunch (without re-seeding) the item still says "In Reminders".
    @MainActor
    func testAddToReminders() throws {
        XCUIApplication().resetAuthorizationStatus(for: .reminders)
        let app = launch(["-interactionTrace"])          // the press timings, for `log stream`
        _ = openBudgetItems(app)
        choose("Add to Reminders", forItem: 0, app)
        XCTAssertTrue(answerRemindersAlert(allow: true), "iOS asks for Reminders")
        let added = NSPredicate(format: "label CONTAINS 'In Reminders'")
        XCTAssertTrue(app.descendants(matching: .any).matching(added).firstMatch.waitForExistence(timeout: 10),
                      "the item says In Reminders: \(item(0, app).label)")
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), item(0, app).label)
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), "only that one")
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "Add All only while two aren't added")
        shot("Added to Reminders", app)

        let menu = app.buttons["ActionItemMenu.0"]
        XCTAssertEqual(menu.label, "More for “Send the numbers to finance”", "VoiceOver: the menu holds more than adding")
        XCTAssertEqual(menu.value as? String, "In Reminders", "and says where it was added")
        XCTAssertEqual(app.buttons["ActionItemMenu.1"].value as? String ?? "", "", "the other one is nowhere yet")

        // Once added, the choice says so (one tap on it can't add it twice by mistake), still there for a reminder
        // deleted in Reminders.
        menu.tap()
        XCTAssertTrue(app.buttons["Add to Calendar"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add to Reminders Again"].isEnabled, "offered again")
        XCTAssertFalse(app.buttons["Add to Reminders"].exists, "not as the first time")
        shot("Menu of an added item", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.08)).tap()   // outside the menu: closes it

        // What arrived in Reminders (read back and removed); the run's day decides the Friday: the seeded meeting
        // was a day ago.
        let reminders = takeReminders(app)
        let friday = next(6, after: .now.addingTimeInterval(-86_400))
        XCTAssertTrue(reminders.contains { line in
            let fields = line.components(separatedBy: " | ")
            return fields.count == 5 && fields[0] == "Send the numbers to finance" && fields[1] == friday
                && fields[2] == "no alarm" && fields[3] == Self.budgetLink
                && fields[4].hasPrefix("Anna Schmidt · From “Budget Review”, ")
        }, "the reminder: all day on \(friday), no alarm, the link, the notes: \(reminders)")
        XCTAssertFalse(reminders.contains { $0.hasPrefix("Add the third-quarter forecast |") }, "only that one")

        // Stored: after a relaunch without re-seeding (takeReminders' launch), still in Reminders.
        XCTAssertTrue(app.staticTexts["Budget Review"].waitForExistence(timeout: 15))
        _ = openBudgetItems(app)
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), "stored: \(item(0, app).label)")
    }

    /// Don't Allow at iOS's question is the answer: nothing more is said, the item stays as it was. The next Add to
    /// Reminders (iOS doesn't ask again) brings Feder's alert offering Settings; Cancel leaves the item.
    @MainActor
    func testRemindersDeniedOffersSettings() throws {
        XCUIApplication().resetAuthorizationStatus(for: .reminders)
        let app = launch()
        _ = openBudgetItems(app)
        choose("Add to Reminders", forItem: 1, app)
        XCTAssertTrue(answerRemindersAlert(allow: false), "iOS asks for Reminders: Don't Allow")
        let alert = app.alerts["Allow Access to Reminders"]
        XCTAssertFalse(alert.waitForExistence(timeout: 4), "no second alert right after Don't Allow")
        XCTAssertTrue(app.buttons["ActionItemMenu.1"].waitForExistence(timeout: 5), "the menu's back (no spinner)")
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), item(1, app).label)

        choose("Add to Reminders", forItem: 1, app)
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the next try: Feder's alert")
        XCTAssertTrue(alert.buttons["Open Settings"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        shot("Reminders denied", app)
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), item(1, app).label)
        XCUIApplication().resetAuthorizationStatus(for: .reminders)   // the next test starts from iOS's question
    }

    /// Add to Calendar shows Apple's New Event editor over the card, prefilled with the task (it runs in its own
    /// process and asks for no permission); Cancel leaves the item, Add marks it "In Calendar". The editor's own
    /// controls are out of XCUITest's reach (another process: the app's tree shows only an empty container, and
    /// `app.screenshot()` an empty sheet), so they are tapped where iOS 27 draws them: the close button at the sheet's
    /// top left, the checkmark (Add) at its top right; the screen's screenshot shows the editor.
    @MainActor
    func testAddToCalendarOpensEditor() throws {
        let app = launch(["-interactionTrace"])
        _ = openBudgetItems(app)
        let back = app.buttons["Minimize"]
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let close = screen.withOffset(CGVector(dx: 38, dy: 100))
        let confirm = screen.withOffset(CGVector(dx: app.frame.width - 38, dy: 100))

        choose("Add to Calendar", forItem: 0, app)
        XCTAssertTrue(waitFor({ !back.isHittable }, timeout: 10), "the editor covers the card")
        sleep(4)                                                // the remote editor draws its content
        screenShot("New Event editor")
        close.tap()
        XCTAssertTrue(waitFor({ back.isHittable }, timeout: 10), "the close button closes it")
        XCTAssertFalse(item(0, app).label.contains("In Calendar"), "cancelled: not added: \(item(0, app).label)")

        choose("Add to Calendar", forItem: 0, app)
        XCTAssertTrue(waitFor({ !back.isHittable }, timeout: 10), "the editor again")
        sleep(4)
        confirm.tap()
        XCTAssertTrue(waitFor({ back.isHittable }, timeout: 10), "Add closes it")
        XCTAssertTrue(waitFor({ self.item(0, app).label.contains("In Calendar") }, timeout: 10),
                      "added: \(item(0, app).label)")
        XCTAssertFalse(item(1, app).label.contains("In Calendar"), "only that one")
        shot("Added to Calendar", app)
    }

    /// The whole screen (the out-of-process editor shows in it, not in `app.screenshot()`).
    @MainActor
    private func screenShot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Remove takes an item away at once (a suggestion: no question) with an Undo toast, as a correction's; the count
    /// follows. Undo puts it back. Both removed, the row goes; Undo brings it back as it was, open. Untouched, the toast
    /// goes after a few seconds and the item stays removed. (Undo order with a correction: testUndoTakesBackTheRemoveFirst.)
    @MainActor
    func testRemoveItem() throws {
        let app = launch(["-interactionTrace"])          // the Remove press's timing, for `log stream`
        let row = openBudgetItems(app)
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3), "removed")
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("1"), "one left: \(row.value ?? "")")
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "Add All needs two")
        let undo = app.buttons["UndoRemoveActionItem"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "the Undo toast")
        XCTAssertTrue(app.staticTexts["Action Item Removed"].exists, "saying what was done")
        shot("Item removed", app)
        undo.tap()
        XCTAssertTrue(item(1, app).waitForExistence(timeout: 3), "Undo puts it back")
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("2"), "two again: \(row.value ?? "")")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 3), "the toast goes")

        // Both: the row goes; Undo brings back the last one, the row still open.
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3))
        choose("Remove", forItem: 0, app)
        XCTAssertTrue(row.waitForNonExistence(timeout: 3), "no items: no row")
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        shot("All items removed", app)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the row is back")
        XCTAssertTrue(item(0, app).waitForExistence(timeout: 3), "open, as it was")
        XCTAssertTrue(item(0, app).label.contains("Send the numbers to finance"), item(0, app).label)
        XCTAssertFalse(item(1, app).exists, "only the last Remove is undone by the toast")

        // Left alone, the toast goes and the item stays removed.
        choose("Remove", forItem: 0, app)
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(undo.waitForNonExistence(timeout: 12), "the toast times out")
        XCTAssertFalse(row.exists, "still removed")
    }

    /// Undo after a correction and then a Remove takes back the Remove first (the newest), the correction next: a
    /// shake undid the correction and left the removed item gone for good. Budget Review's second turn goes to Lena
    /// Vogel, then the second item is removed (its toast replaces the correction's). XCUITest can't shake (and the
    /// simulator's shake notification doesn't reach iOS 27), so ⌘Z on the connected hardware keyboard undoes: the same
    /// window UndoManager the shake asks.
    @MainActor
    func testUndoTakesBackTheRemoveFirst() throws {
        let app = launch()
        open("Budget Review", in: app)
        let names = {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'SpeakerHeader.'")).allElementsBoundByIndex
                .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
        }
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)
        let assign = app.buttons["Assign This Part To"]
        XCTAssertTrue(assign.waitForExistence(timeout: 5))
        assign.tap()
        let lena = app.buttons["Lena Vogel"].firstMatch
        XCTAssertTrue(lena.waitForExistence(timeout: 5))
        lena.tap()
        XCTAssertTrue(waitFor({ names() == ["Lena Vogel", "Anna Schmidt"] }, timeout: 5), "corrected: \(names())")
        XCTAssertTrue(app.buttons["UndoCorrection"].waitForExistence(timeout: 5), "the correction's toast")

        app.buttons["ActionItems"].tap()
        XCTAssertTrue(item(1, app).waitForExistence(timeout: 3))
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(app.buttons["UndoRemoveActionItem"].waitForExistence(timeout: 3), "the Remove's toast")
        XCTAssertFalse(app.buttons["UndoCorrection"].exists, "one toast at a time")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(item(1, app).waitForExistence(timeout: 5), "the Remove first: the item is back")
        XCTAssertTrue(app.buttons["UndoRemoveActionItem"].waitForNonExistence(timeout: 3), "its toast went with it")
        XCTAssertEqual(names(), ["Lena Vogel", "Anna Schmidt"], "the correction stays")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitFor({ names() == ["Lena Vogel", "Anna Schmidt", "Lena Vogel", "Anna Schmidt"] }, timeout: 5),
                      "then the correction: \(names())")
        XCTAssertTrue(item(1, app).exists, "the item stays")
    }

    /// After Stop the pipeline finds the action items (`-fakeGemma`: two canned items, one due "by Friday", one
    /// "tomorrow at 10:00"): the status line says "Finding action items…", then the Action Items row stands where its
    /// place was held, so the transcript doesn't move; the first item's date is the Friday after today; Add All to
    /// Reminders adds both: in Reminders, the first all day without an alarm, the second at 10:00 tomorrow with an
    /// alarm then, both with the transcript's link. The recording is deleted again.
    @MainActor
    func testPipelineFindsActionItems() throws {
        XCUIApplication().terminate()
        let app = launch(["-fakeGemma", "-autoRecord", "-autoStopAfter", "6"])
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 30), "saved: the transcript")
        let status = app.staticTexts["PipelineStatus"]
        XCTAssertTrue(status.wait(for: \.label, toEqual: "Finding action items…", timeout: 40),
                      "the status line: \(status.exists ? status.label : "gone")")
        let firstName = app.buttons["SpeakerHeader.0"]
        XCTAssertTrue(firstName.exists, "the speakers are there")
        let before = firstName.frame
        shot("Finding action items", app)

        let row = app.buttons["ActionItems"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Action Items row")
        XCTAssertTrue(status.waitForNonExistence(timeout: 5), "the status line is gone")
        sleep(1)
        XCTAssertEqual(firstName.frame.minY, before.minY, accuracy: 1, "the transcript didn't move: \(firstName.frame) \(before)")
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("2"), "two items: \(row.value ?? "")")
        shot("Action items found", app)

        row.tap()
        let first = item(0, app)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(first.label.contains("Send the test results to the team"), first.label)
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US")
        let today = calendar.startOfDay(for: .now)
        var ahead = (6 - calendar.component(.weekday, from: today) + 7) % 7
        if ahead == 0 { ahead = 7 }
        let friday = calendar.date(byAdding: .day, value: ahead, to: today)!
        let day = calendar.component(.day, from: friday)
        XCTAssertTrue(first.label.contains("Fri") && first.label.contains("\(day)"),
                      "due the Friday after today (\(friday)): \(first.label)")
        shot("Pipeline items open", app)

        // Add All: both in one go (iOS asks first when no earlier test was allowed access).
        app.buttons["AddAllToReminders"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 5) { XCTAssertTrue(answerRemindersAlert(allow: true)) }
        XCTAssertTrue(waitFor({ self.item(1, app).label.contains("In Reminders") }, timeout: 10),
                      "both added: \(item(1, app).label)")
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), item(0, app).label)
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "nothing left to add")
        shot("All added to Reminders", app)

        app.buttons["Delete Transcript"].tap()                   // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))

        let reminders = takeReminders(app).map { $0.components(separatedBy: " | ") }
        let tomorrow = Self.ymd(calendar.date(byAdding: .day, value: 1, to: today)!) + " 10:00"
        let results = reminders.first { $0.first == "Send the test results to the team" } ?? []
        let check = reminders.first { $0.first == "Check the provisional words" } ?? []
        XCTAssertEqual(results.count, 5, "in Reminders: \(reminders)")
        XCTAssertEqual(check.count, 5, "both: \(reminders)")
        guard results.count == 5, check.count == 5 else { return }
        XCTAssertEqual(results[1], Self.ymd(friday), "all day on Friday")
        XCTAssertEqual(results[2], "no alarm", "no time said: Reminders' own all-day notification")
        XCTAssertEqual(check[1], tomorrow, "a time said: that time")
        XCTAssertEqual(check[2], tomorrow, "and an alarm then")
        XCTAssertTrue(results[3].hasPrefix("feder://transcript/"), "the transcript's link: \(results[3])")
        XCTAssertEqual(check[3], results[3], "the same transcript")
        XCTAssertTrue(results[4].hasPrefix("From “"), "where from, nobody named: \(results[4])")
    }

    /// "Speakers: n" with Gemma there (`-fakeGemma`) on a transcript whose items are current: the status line covers the
    /// summary as before, and the open items stay where they are, reachable, while the speakers are identified again
    /// (the step was listed, so the open items folded into a hidden row, came back folded, and a transcript without
    /// items got a blank row): the AI note under them doesn't move.
    @MainActor
    func testSpeakerCountKeepsTheItems() throws {
        let app = launch(["-fakeGemma", "-fakeDiarizeSeconds", "4"])
        open("Budget Review", in: app)
        let status = app.staticTexts["PipelineStatus"]
        // -fakeGemma's launch sweep writes the seeded transcripts' summaries again first.
        XCTAssertTrue(status.waitForNonExistence(timeout: 30), "the launch sweep is done")
        let row = app.buttons["ActionItems"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(item(0, app).waitForExistence(timeout: 3))
        sleep(1)
        let note = app.staticTexts["AINotice"]
        let before = note.frame.minY

        app.buttons["Speakers"].tap()
        let three = app.buttons["3 Speakers"]
        XCTAssertTrue(three.waitForExistence(timeout: 5))
        three.tap()
        let again = app.buttons["Identify Again"]
        XCTAssertTrue(again.waitForExistence(timeout: 5), "named speakers: asked first")
        again.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the status line while the speakers are identified")
        sleep(1)
        XCTAssertTrue(item(0, app).exists, "the open items stay")
        XCTAssertTrue(item(0, app).isHittable, "and reachable")
        XCTAssertEqual(note.frame.minY, before, accuracy: 1, "nothing moved: \(note.frame.minY) \(before)")
        shot("Speakers again, items open", app)

        XCTAssertTrue(status.waitForNonExistence(timeout: 40), "identified again")
        sleep(1)
        XCTAssertTrue(item(0, app).exists, "still open")
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("2"), "the same two: \(row.value ?? "")")
        XCTAssertEqual(note.frame.minY, before, accuracy: 1, "no blank row: \(note.frame.minY) \(before)")
    }

    /// feder://transcript/<id> (the link of an item added to Reminders or Calendar) opens that transcript's card.
    @MainActor
    func testDeepLinkOpensTranscript() throws {
        let app = launch()
        app.open(URL(string: "feder://transcript/5C0FFEE0-0000-4000-8000-000000000002")!)   // Budget Review
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].waitForExistence(timeout: 10), "the card opens")
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        closeCard(app)
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
