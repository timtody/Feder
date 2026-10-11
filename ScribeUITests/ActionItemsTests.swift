import XCTest

/// Action items (ActionItemExtractor, the card's "Action Items" row under Summary): folded until tapped, added to
/// Reminders (EventKit, full access asked at the first add) and Calendar (Apple's New Event editor), removed; found by
/// the pipeline after Stop (`-fakeGemma`: FakeTextWriter answers with two items); a transcript's link from Reminders
/// (feder://transcript/<id>) opens its card. "Budget Review" is seeded with two items: "Send the numbers to finance"
/// (Anna Schmidt, by Friday) and "Add the third-quarter forecast" (Anna Schmidt).
final class ActionItemsTests: ScribeUITestCase {
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

    /// iOS's question for Reminders (springboard): taps the button whose label starts with `prefix`.
    @MainActor
    private func answerRemindersAlert(_ prefix: String) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 10) else { return false }
        note("Reminders alert", alert.debugDescription)
        let button = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
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
    /// menu's plus turns into a checkmark; after a relaunch (without re-seeding) it still does.
    @MainActor
    func testAddToReminders() throws {
        XCUIApplication().resetAuthorizationStatus(for: .reminders)
        let app = launch(["-interactionTrace"])          // the press timings, for `log stream`
        _ = openBudgetItems(app)
        choose("Add to Reminders", forItem: 0, app)
        XCTAssertTrue(answerRemindersAlert("Allow"), "iOS asks for Reminders")
        let added = NSPredicate(format: "label CONTAINS 'In Reminders'")
        XCTAssertTrue(app.descendants(matching: .any).matching(added).firstMatch.waitForExistence(timeout: 10),
                      "the item says In Reminders: \(item(0, app).label)")
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), item(0, app).label)
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), "only that one")
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "Add All only while two aren't added")
        shot("Added to Reminders", app)

        // The menu offers it no more (one tap would add it twice).
        app.buttons["ActionItemMenu.0"].tap()
        XCTAssertTrue(app.buttons["Add to Calendar"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Add to Reminders"].isEnabled, "already in Reminders")
        shot("Menu of an added item", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.08)).tap()   // outside the menu: closes it

        // Stored: after a relaunch without re-seeding, still in Reminders.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-seedSamples" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Budget Review"].waitForExistence(timeout: 15))
        _ = openBudgetItems(app)
        XCTAssertTrue(item(0, app).label.contains("In Reminders"), "stored: \(item(0, app).label)")
    }

    /// Reminders denied: Feder's alert offers Settings (iOS never asks again); Cancel leaves the item as it was.
    @MainActor
    func testRemindersDeniedOffersSettings() throws {
        XCUIApplication().resetAuthorizationStatus(for: .reminders)
        let app = launch()
        _ = openBudgetItems(app)
        choose("Add to Reminders", forItem: 1, app)
        XCTAssertTrue(answerRemindersAlert("Don"), "iOS asks for Reminders: Don't Allow")
        let alert = app.alerts["Allow Access to Reminders"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Feder's alert")
        XCTAssertTrue(alert.buttons["Open Settings"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        shot("Reminders denied", app)
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(item(1, app).label.contains("In Reminders"), item(1, app).label)
        XCUIApplication().resetAuthorizationStatus(for: .reminders)   // the next test starts from iOS's question
    }

    /// Add to Calendar shows Apple's New Event editor over the card, prefilled with the task (it runs in its own
    /// process and asks for no permission); Cancel leaves the item, Add marks it "In Calendar".
    @MainActor
    func testAddToCalendarOpensEditor() throws {
        let app = launch(["-interactionTrace"])
        _ = openBudgetItems(app)
        choose("Add to Calendar", forItem: 0, app)
        let back = app.buttons["Minimize"]
        XCTAssertTrue(waitFor({ !back.isHittable }, timeout: 10), "the editor covers the card")
        sleep(2)
        shot("New Event editor", app)
        note("Editor tree", app.debugDescription)
        // The editor's own buttons, when XCUITest reaches them (out of process, like the file picker: maybe not).
        let add = app.navigationBars.buttons["Add"].firstMatch
        if add.exists {
            XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == 'Send the numbers to finance'"))
                .firstMatch.exists || app.staticTexts["Send the numbers to finance"].exists, "prefilled with the task")
            app.navigationBars.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(waitFor({ back.isHittable }, timeout: 5), "Cancel closes it")
            XCTAssertFalse(item(0, app).label.contains("In Calendar"), "cancelled: not added")
            choose("Add to Calendar", forItem: 0, app)
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            XCTAssertTrue(waitFor({ back.isHittable }, timeout: 5), "Add closes it")
            XCTAssertTrue(waitFor({ self.item(0, app).label.contains("In Calendar") }, timeout: 5),
                          "added: \(item(0, app).label)")
            shot("Added to Calendar", app)
        } else {
            // Not reachable: closed like a sheet, the item unchanged.
            for _ in 0..<3 where !back.isHittable {
                app.swipeDown(velocity: .fast)
                _ = waitFor({ back.isHittable }, timeout: 4)
            }
            XCTAssertTrue(back.isHittable, "the editor closed")
            XCTAssertFalse(item(0, app).label.contains("In Calendar"))
        }
    }

    /// Remove takes an item away at once (a suggestion: no question); the count follows.
    @MainActor
    func testRemoveItem() throws {
        let app = launch()
        let row = openBudgetItems(app)
        choose("Remove", forItem: 1, app)
        XCTAssertTrue(waitFor({ !self.item(1, app).exists }, timeout: 3), "removed")
        XCTAssertTrue((row.value as? String ?? "").hasPrefix("1"), "one left: \(row.value ?? "")")
        XCTAssertFalse(app.buttons["AddAllToReminders"].exists, "Add All needs two")
        shot("Item removed", app)
    }

    /// After Stop the pipeline finds the action items (`-fakeGemma`: two canned items, one due "by Friday"): the status
    /// line says "Finding action items…", then the Action Items row stands where its place was held, so the transcript
    /// doesn't move; the first item's date is the Friday after today. The recording is deleted again.
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

        app.buttons["Delete Transcript"].tap()                   // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
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
