import XCTest

/// Action items (ActionItemExtractor, the card's Action Items button and sheet; the button only where Gemma can run, so
/// the tests pass `-fakeGemmaDownload`: an iPhone that can run it, not downloaded, or `-fakeGemma`): shown at once
/// where they were found before, looked for only when the button asks (`-fakeGemma`: FakeTextWriter answers with two items, one due on a day,
/// one at a time; never after Stop or by a sweep), added to Reminders (EventKit, full access asked at the first add;
/// what arrived there is read back and removed with `-federRemindersReport`) and Calendar (Apple's New Event editor),
/// removed and put back (Undo); a transcript's link from Reminders (feder://transcript/<id>) opens its card. "Budget
/// Review" is seeded with two items: "Send the numbers to finance" (Anna Schmidt, by Friday) and "Add the third-quarter
/// forecast" (Anna Schmidt).
final class ActionItemsTests: ScribeUITestCase {
    static let budgetLink = "feder://transcript/5C0FFEE0-0000-4000-8000-000000000002"
    /// An item's row: the task with who and when under it, one accessibility element.
    @MainActor
    private func item(_ index: Int, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["ActionItem.\(index)"].firstMatch
    }

    /// The card's Action Items button (the bottom toolbar's checklist).
    @MainActor
    private func actionItemsButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Action Items"].firstMatch
    }

    /// Budget Review's card, and its Action Items sheet with the two stored items.
    @MainActor
    private func openBudgetItems(_ app: XCUIApplication) {
        open("Budget Review", in: app)
        let button = actionItemsButton(app)
        XCTAssertTrue(button.appears(timeout: 5), "the Action Items button")
        button.tap()
        XCTAssertTrue(item(0, app).appears(timeout: 5), "the sheet shows the items")
    }

    /// The visible items' count (ActionItem.0, .1, …).
    @MainActor
    private func itemCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'ActionItem.'")).count
    }

    /// Chooses `choice` in item `index`'s menu.
    @MainActor
    private func choose(_ choice: String, forItem index: Int, _ app: XCUIApplication) {
        let menu = app.buttons["ActionItemMenu.\(index)"]
        XCTAssertTrue(menu.appears(timeout: 3), "the item's menu")
        menu.tap()
        let button = app.buttons[choice].firstMatch
        XCTAssertTrue(button.appears(timeout: 3), "\(choice) in the menu")
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
        XCTAssertTrue(alert.appears(timeout: 20), "the report")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).first { $0 != "Feder Reminders" } ?? ""
        note("Feder's reminders", message)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.disappears(timeout: 5))
        return message.split(separator: "\n").map(String.init)
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
        guard alert.appears(timeout: 15) else { return false }
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

    /// Budget Review's items were found before: the toolbar's Action Items (between Find and Listen, where the
    /// speaker-count menu was) opens the sheet with them at once, without Gemma (`-fakeGemmaDownload`: not downloaded),
    /// each with who and when (the first one's due date is a Friday), Add All, and the AI note; no Find Again while Gemma
    /// can't run. Nothing of them under the summary any more. The close button closes the sheet.
    @MainActor
    func testButtonShowsStoredItems() throws {
        let app = launch(["-fakeGemmaDownload"])
        open("Budget Review", in: app)
        XCTAssertFalse(app.buttons["ActionItems"].exists, "no Action Items row under the summary")
        XCTAssertFalse(app.buttons["Speakers"].exists, "no speaker-count menu")
        let button = actionItemsButton(app)
        XCTAssertTrue(button.appears(timeout: 5) && button.isEnabled, "the Action Items button")
        XCTAssertLessThan(app.buttons["FindButton"].frame.minX, button.frame.minX, "after Find")
        XCTAssertLessThan(button.frame.minX, app.buttons["Listen"].frame.minX, "before Listen")
        button.tap()
        XCTAssertTrue(app.navigationBars["Action Items"].appears(timeout: 5), "the sheet")
        let first = item(0, app)
        XCTAssertTrue(first.appears(timeout: 3), "the stored items at once")
        XCTAssertFalse(app.descendants(matching: .any)["FindingActionItems"].exists, "Gemma isn't asked")
        XCTAssertTrue(first.label.contains("Send the numbers to finance"), first.label)
        XCTAssertTrue(first.label.contains("Anna Schmidt"), "who: \(first.label)")
        XCTAssertTrue(first.label.contains("Fri"), "by Friday, as a date: \(first.label)")
        XCTAssertTrue(item(1, app).label.contains("Add the third-quarter forecast"), item(1, app).label)
        XCTAssertTrue(app.buttons["AddAllToReminders"].exists, "Add All while two aren't in Reminders")
        XCTAssertTrue(app.staticTexts["AI-generated content can contain mistakes."].exists, "the AI note")
        XCTAssertTrue(app.buttons["Share"].exists, "Share for the list")
        XCTAssertFalse(app.buttons["Find Again"].exists, "no Find Again while Gemma can't run")
        shot("Action items sheet", app)

        app.buttons["CloseActionItems"].tap()
        XCTAssertTrue(first.disappears(timeout: 5), "closed")
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].isHittable, "back on the card")
    }

    /// Add to Reminders asks for full access the first time (iOS's alert), then the item says "In Reminders" and its
    /// menu's plus turns into a checkmark (VoiceOver: its value); the menu then offers "Add to Reminders Again". In
    /// Reminders: the task, due all day on the Friday after the meeting (no time said: no alarm), the transcript's link
    /// and who and where from in the notes. After a relaunch (without re-seeding) the item still says "In Reminders".
    @MainActor
    func testAddToReminders() throws {
        XCUIApplication().resetAuthorizationStatus(for: .reminders)
        let app = launch(["-interactionTrace", "-fakeGemmaDownload"])   // the press timings, for `log stream`
        openBudgetItems(app)
        choose("Add to Reminders", forItem: 0, app)
        XCTAssertTrue(answerRemindersAlert(allow: true), "iOS asks for Reminders")
        let added = NSPredicate(format: "label CONTAINS 'In Reminders'")
        XCTAssertTrue(app.descendants(matching: .any).matching(added).firstMatch.appears(timeout: 10),
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
        XCTAssertTrue(app.buttons["Add to Calendar"].appears(timeout: 3))
        XCTAssertTrue(app.buttons["Add to Reminders Again"].isEnabled, "offered again")
        XCTAssertFalse(app.buttons["Add to Reminders"].exists, "not as the first time")
        shot("Menu of an added item", app)
        app.navigationBars["Action Items"].tap()            // outside the menu: closes it

        // What arrived in Reminders (read back and removed); the run's day decides the Friday: the seeded meeting
        // was a day ago.
        let reminders = takeReminders(app)
        let friday = Self.ymd(next(6, after: .now.addingTimeInterval(-86_400)))
        XCTAssertTrue(reminders.contains { line in
            let fields = line.components(separatedBy: " | ")
            return fields.count == 5 && fields[0] == "Send the numbers to finance" && fields[1] == friday
                && fields[2] == "no alarm" && fields[3] == Self.budgetLink
                && fields[4].hasPrefix("Anna Schmidt · From “Budget Review”, ")
        }, "the reminder: all day on \(friday), no alarm, the link, the notes: \(reminders)")
        XCTAssertFalse(reminders.contains { $0.hasPrefix("Add the third-quarter forecast |") }, "only that one")

        // Stored: after a relaunch without re-seeding (takeReminders' launch), still in Reminders.
        XCTAssertTrue(app.staticTexts["Budget Review"].appears(timeout: 15))
        openBudgetItems(app)
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), "stored: \(item(0, app).label)")
    }

    /// Don't Allow at iOS's question is the answer: nothing more is said, the item stays as it was. The next Add to
    /// Reminders (iOS doesn't ask again) brings Feder's alert offering Settings; Cancel leaves the item.
    @MainActor
    func testRemindersDeniedOffersSettings() throws {
        XCUIApplication().resetAuthorizationStatus(for: .reminders)
        let app = launch(["-fakeGemmaDownload"])
        openBudgetItems(app)
        choose("Add to Reminders", forItem: 1, app)
        XCTAssertTrue(answerRemindersAlert(allow: false), "iOS asks for Reminders: Don't Allow")
        let alert = app.alerts["Allow Access to Reminders"]
        XCTAssertFalse(alert.appears(timeout: 4), "no second alert right after Don't Allow")
        XCTAssertTrue(app.buttons["ActionItemMenu.1"].appears(timeout: 5), "the menu's back (no spinner)")
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), item(1, app).label)

        choose("Add to Reminders", forItem: 1, app)
        XCTAssertTrue(alert.appears(timeout: 10), "the next try: Feder's alert")
        XCTAssertTrue(alert.buttons["Open Settings"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        shot("Reminders denied", app)
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), item(1, app).label)
        XCUIApplication().resetAuthorizationStatus(for: .reminders)   // the next test starts from iOS's question
    }

    /// Add to Calendar shows Apple's New Event editor over the sheet, prefilled with the task (it runs in its own
    /// process and asks for no permission); Cancel leaves the item, Add marks it "In Calendar". The editor's own
    /// controls are out of XCUITest's reach (another process: the app's tree shows only an empty container, and
    /// `app.screenshot()` an empty sheet), so they are tapped where iOS 27 draws them: the close button at the sheet's
    /// top left, the checkmark (Add) at its top right; the screen's screenshot shows the editor.
    @MainActor
    func testAddToCalendarOpensEditor() throws {
        let app = launch(["-interactionTrace", "-fakeGemmaDownload"])
        openBudgetItems(app)
        let back = app.buttons["CloseActionItems"]          // the sheet's: covered while the editor is up
        let screen = app.coordinate(withNormalizedOffset: .zero)
        let close = screen.withOffset(CGVector(dx: 38, dy: 100))
        let confirm = screen.withOffset(CGVector(dx: app.frame.width - 38, dy: 100))

        choose("Add to Calendar", forItem: 0, app)
        XCTAssertTrue(waitFor({ !back.isHittable }, timeout: 10), "the editor covers the sheet")
        sleep(4)                                                // the remote editor draws its content
        screenShot("New Event editor")
        XCTAssertTrue(tapEditor(close, until: back), "the close button closes it")
        XCTAssertFalse(item(0, app).label.contains("In Calendar"), "cancelled: not added: \(item(0, app).label)")

        choose("Add to Calendar", forItem: 0, app)
        XCTAssertTrue(waitFor({ !back.isHittable }, timeout: 10), "the editor again")
        sleep(4)
        XCTAssertTrue(tapEditor(confirm, until: back), "Add closes it")
        XCTAssertTrue(waitFor({ self.item(0, app).label.contains("In Calendar") }, timeout: 10),
                      "added: \(item(0, app).label)")
        XCTAssertFalse(item(1, app).label.contains("In Calendar"), "only that one")
        shot("Added to Calendar", app)
    }

    /// Taps a point of the out-of-process New Event editor, again every 5 s while the editor stays up (the sheet's
    /// `back` covered): in a parallel run on a freshly cloned simulator the editor was still blank 4 s after it came up,
    /// and one tap hit nothing (2026-10-13). 5 s apart, so a tap that worked has closed it before the next could land on
    /// the sheet.
    @MainActor
    private func tapEditor(_ point: XCUICoordinate, until back: XCUIElement) -> Bool {
        for _ in 0..<4 {
            point.tap()
            if waitFor({ back.isHittable }, timeout: 5) { return true }
        }
        return false
    }

    /// The whole screen (the out-of-process editor shows in it, not in `app.screenshot()`).
    @MainActor
    private func screenShot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Remove takes an item away at once (a suggestion: no question) with an Undo toast, as a correction's. Undo puts it
    /// back. Both removed, the sheet says No Action Items; Undo brings back the last one. Untouched, the toast goes after
    /// a few seconds and the item stays removed. (Undo order with a correction: testUndoTakesBackTheRemoveFirst.)
    @MainActor
    func testRemoveItem() throws {
        let app = launch(["-interactionTrace", "-fakeGemmaDownload"])   // the Remove press's timing, for `log stream`
        openBudgetItems(app)
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3), "removed")
        XCTAssertEqual(itemCount(app), 1, "one left")
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "Add All needs two")
        let undo = app.buttons["UndoRemoveActionItem"]
        XCTAssertTrue(undo.appears(timeout: 3), "the Undo toast")
        XCTAssertTrue(app.staticTexts["Action Item Removed"].exists, "saying what was done")
        shot("Item removed", app)
        undo.tap()
        XCTAssertTrue(item(1, app).appears(timeout: 3), "Undo puts it back")
        XCTAssertEqual(itemCount(app), 2, "two again")
        XCTAssertTrue(undo.disappears(timeout: 3), "the toast goes")

        // Both: No Action Items; Undo brings back the last one.
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3))
        choose("Remove", forItem: 0, app)
        let none = app.staticTexts["No Action Items"]
        XCTAssertTrue(none.appears(timeout: 3), "no items left")
        XCTAssertTrue(undo.appears(timeout: 3))
        shot("All items removed", app)
        undo.tap()
        XCTAssertTrue(item(0, app).appears(timeout: 3), "the item is back")
        XCTAssertTrue(item(0, app).label.contains("Send the numbers to finance"), item(0, app).label)
        XCTAssertFalse(item(1, app).exists, "only the last Remove is undone by the toast")

        // Left alone, the toast goes and the item stays removed.
        choose("Remove", forItem: 0, app)
        XCTAssertTrue(undo.appears(timeout: 3))
        XCTAssertTrue(undo.disappears(timeout: 12), "the toast times out")
        XCTAssertTrue(none.exists, "still removed")
    }

    /// Shaking puts back removed items and takes back a correction (iOS's own alert, `shake`), newest first, in the sheet
    /// and after it. In the sheet, before any correction: "Undo Action Item Removed" brings the item back. Removed again
    /// and the sheet closed, with only that removal on offer (the card's view took first responder in the sheet, at the
    /// Remove): a shake still brings it back, and then nothing is left. Then Budget Review's second turn goes to Lena
    /// Vogel, the second item is removed again and the sheet closes: the first shake brings the item back and leaves the
    /// correction, the second undoes the correction, a third has nothing left. (The sheet withdrew the removal's Undo
    /// when it closed, which left an empty step: the first shake did nothing.)
    @MainActor
    func testUndoTakesBackTheRemoveFirst() throws {
        let app = launch(["-fakeGemmaDownload"])
        open("Budget Review", in: app)
        actionItemsButton(app).tap()
        XCTAssertTrue(item(1, app).appears(timeout: 5))
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3), "removed")
        let inSheet = try XCTUnwrap(shake(app), "a shake in the sheet")
        XCTAssertEqual(inSheet.label, "Undo Action Item Removed")
        shot("Shake in the sheet", app)
        inSheet.buttons["Undo"].tap()
        XCTAssertTrue(item(1, app).appears(timeout: 3), "the item is back")
        XCTAssertTrue(app.buttons["UndoRemoveActionItem"].disappears(timeout: 3), "its toast goes")
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3), "removed again")
        app.buttons["CloseActionItems"].tap()
        XCTAssertTrue(item(0, app).disappears(timeout: 5), "the sheet closed")
        let closed = try XCTUnwrap(shake(app), "a shake once the sheet is closed")
        XCTAssertEqual(closed.label, "Undo Action Item Removed")
        closed.buttons["Undo"].tap()
        XCTAssertTrue(closed.disappears(timeout: 3))
        XCTAssertNil(shake(app, timeout: 2), "nothing left to undo")

        let names = {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'SpeakerHeader.'")).allElementsBoundByIndex
                .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
        }
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)
        let assign = app.buttons["Assign This Part To"]
        XCTAssertTrue(assign.appears(timeout: 5))
        assign.tap()
        let lena = app.buttons["Lena Vogel"].firstMatch
        XCTAssertTrue(lena.appears(timeout: 5))
        lena.tap()
        XCTAssertTrue(waitFor({ names() == ["Lena Vogel", "Anna Schmidt"] }, timeout: 5), "corrected: \(names())")
        XCTAssertTrue(app.buttons["UndoCorrection"].appears(timeout: 5), "the correction's toast")

        actionItemsButton(app).tap()
        XCTAssertTrue(item(1, app).appears(timeout: 5), "the item the closed sheet's shake put back")
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(app.buttons["UndoRemoveActionItem"].appears(timeout: 3), "the Remove's toast")
        app.buttons["CloseActionItems"].tap()
        XCTAssertTrue(item(0, app).disappears(timeout: 5), "the sheet closed")

        let first = try XCTUnwrap(shake(app), "the first shake")
        XCTAssertEqual(first.label, "Undo Action Item Removed", "the Remove first")
        first.buttons["Undo"].tap()
        sleep(1)
        XCTAssertEqual(names(), ["Lena Vogel", "Anna Schmidt"], "the correction stays")
        let second = try XCTUnwrap(shake(app), "the second shake")
        XCTAssertEqual(second.label, "Undo Speaker Changed", "then the correction")
        second.buttons["Undo"].tap()
        XCTAssertTrue(waitFor({ names() == ["Lena Vogel", "Anna Schmidt", "Lena Vogel", "Anna Schmidt"] }, timeout: 5),
                      "the correction undone: \(names())")
        XCTAssertNil(shake(app, timeout: 2), "nothing left to undo")
        actionItemsButton(app).tap()
        XCTAssertTrue(item(1, app).appears(timeout: 5), "the item is back")
        XCTAssertEqual(itemCount(app), 2)
    }

    /// After Stop nothing looks for action items (`-fakeGemma`: FakeTextWriter would answer with two, one due "by
    /// Friday", one "tomorrow at 10:00"): the summary is written, the status line never says "Finding action items…".
    /// The Action Items button, greyed until the speakers are final, then opens the sheet, which asks Gemma at once
    /// ("Finding action items…") and shows the two; the first one's date is the Friday after today. Opened again, they
    /// are there at once. Add All to Reminders adds both: in Reminders, the first all day without an alarm, the second
    /// at 10:00 tomorrow with an alarm then, both with the transcript's link. The recording is deleted again.
    @MainActor
    func testButtonFindsActionItems() throws {
        XCUIApplication().terminate()
        let app = launch(["-fakeGemma", "-autoRecord", "-autoStopAfter", "6"])
        XCTAssertTrue(app.buttons["Delete Transcript"].appears(timeout: 30), "saved: the transcript")
        let button = actionItemsButton(app)
        XCTAssertTrue(button.exists, "the Action Items button")
        let status = app.staticTexts["PipelineStatus"]
        var labels: Set<String> = []
        let end = Date.now.addingTimeInterval(60)
        while !app.buttons["Summary"].exists, Date.now < end {        // the steps after Stop, the summary last
            if let line = try? status.snapshot() { labels.insert(line.label) }   // it can go between a check and a read
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        XCTAssertTrue(app.buttons["Summary"].exists, "the summary is written")
        XCTAssertTrue(status.disappears(timeout: 10), "and nothing runs after it")
        XCTAssertFalse(labels.contains("Finding action items…"), "no action items after Stop: \(labels)")
        XCTAssertTrue(button.isEnabled, "the button once the speakers are final")
        shot("Summary, no action items", app)

        button.tap()
        let finding = app.descendants(matching: .any)["FindingActionItems"]
        XCTAssertTrue(finding.appears(timeout: 5), "the sheet asks Gemma at once")
        shot("Finding action items", app)
        let first = item(0, app)
        XCTAssertTrue(first.appears(timeout: 20), "the items found")
        XCTAssertFalse(finding.exists)
        XCTAssertTrue(first.label.contains("Send the test results to the team"), first.label)
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US")
        let today = calendar.startOfDay(for: .now)
        let friday = next(6, after: today)
        let day = calendar.component(.day, from: friday)
        XCTAssertTrue(first.label.contains("Fri") && first.label.contains("\(day)"),
                      "due the Friday after today (\(friday)): \(first.label)")
        XCTAssertTrue(app.buttons["Find Again"].exists, "Find Again with Gemma")
        shot("Action items found", app)

        app.buttons["CloseActionItems"].tap()
        XCTAssertTrue(first.disappears(timeout: 5))
        button.tap()
        XCTAssertTrue(first.appears(timeout: 3), "opened again: at once")
        XCTAssertFalse(finding.exists, "not asked again")

        // Add All: both in one go (iOS asks first when no earlier test was allowed access).
        app.buttons["AddAllToReminders"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.appears(timeout: 5) { XCTAssertTrue(answerRemindersAlert(allow: true)) }
        XCTAssertTrue(waitFor({ self.item(1, app).label.contains("In Reminders") }, timeout: 10),
                      "both added: \(item(1, app).label)")
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), item(0, app).label)
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "nothing left to add")
        shot("All added to Reminders", app)

        app.buttons["CloseActionItems"].tap()
        XCTAssertTrue(first.disappears(timeout: 5))
        app.buttons["Delete Transcript"].tap()                   // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5))

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

    /// Find Again asks Gemma once more (`-fakeGemma` answers with Budget Review's two items) and keeps what was done with
    /// the items found before: one removed stays removed, the other comes back as it was.
    @MainActor
    func testFindAgainKeepsRemovedItems() throws {
        let app = launch(["-fakeGemma"])
        openBudgetItems(app)
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ self.itemCount(app) == 1 }, timeout: 3), "removed")
        app.buttons["Find Again"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["FindingActionItems"].appears(timeout: 5), "Gemma asked")
        XCTAssertTrue(item(0, app).appears(timeout: 40), "found again")
        sleep(1)
        XCTAssertEqual(itemCount(app), 1, "the removed one stays removed")
        XCTAssertTrue(item(0, app).label.contains("Send the numbers to finance"), item(0, app).label)
        shot("Found again", app)
    }

    /// Never in the background, never into the archive (`-seedOldTranscripts`: the samples never described and never
    /// looked for action items; Budget Review ten days old). With Gemma there (`-fakeGemma`) the launch sweep writes
    /// Project Kickoff's summary again (made today) but stores no action items: its sheet then asks Gemma. Budget
    /// Review, beyond the three days, gets nothing written again and keeps its own two items.
    @MainActor
    func testNoActionItemsWithoutTheButton() throws {
        let app = launch(["-fakeGemma", "-seedOldTranscripts"])
        open("Project Kickoff", in: app)
        // Seeded without a summary: one appears once the sweep has described it (it may be done before the card is up).
        XCTAssertTrue(app.buttons["Summary"].appears(timeout: 40), "the launch sweep wrote its summary")
        let status = app.staticTexts["PipelineStatus"]
        XCTAssertTrue(status.disappears(timeout: 30), "and is done")
        sleep(2)
        actionItemsButton(app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["FindingActionItems"].appears(timeout: 5),
                      "nothing stored: the sheet asks Gemma now")
        shot("Older transcript, asked by the button", app)
        app.buttons["CloseActionItems"].tap()
        closeCard(app)
        open("Budget Review", in: app)
        XCTAssertFalse(status.appears(timeout: 10), "ten days old: nothing written again")
        XCTAssertEqual(app.buttons["Summary"].value as? String, SummaryTests.summary, "its own summary stays")
        actionItemsButton(app).tap()
        XCTAssertTrue(item(1, app).appears(timeout: 5), "its own two")
        XCTAssertEqual(itemCount(app), 2)
    }

    /// Gemma not downloaded (`-fakeGemmaDownload`: this iPhone could run it): the sheet says where to get it instead of
    /// a spinner.
    @MainActor
    func testWithoutGemmaSaysSo() throws {
        let app = launch(["-fakeGemmaDownload", "-seedOldTranscripts"])
        open("Project Kickoff", in: app)
        let button = actionItemsButton(app)
        XCTAssertTrue(button.appears(timeout: 5) && button.isEnabled, "the button: Gemma can run here")
        button.tap()
        XCTAssertTrue(app.staticTexts["Gemma Needed"].appears(timeout: 5), "it says Gemma is needed")
        XCTAssertFalse(app.descendants(matching: .any)["FindingActionItems"].exists)
        shot("Gemma needed", app)
    }

    /// feder://transcript/<id> (the link of an item added to Reminders or Calendar) opens that transcript's card.
    @MainActor
    func testDeepLinkOpensTranscript() throws {
        let app = launch()
        app.open(URL(string: "feder://transcript/5C0FFEE0-0000-4000-8000-000000000002")!)   // Budget Review
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].appears(timeout: 10), "the card opens")
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        closeCard(app)
    }

}
