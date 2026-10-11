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
    /// menu's plus turns into a checkmark; after a relaunch (without re-seeding) it still does.
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
        XCTAssertTrue(answerRemindersAlert(allow: false), "iOS asks for Reminders: Don't Allow")
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
    /// doesn't move; the first item's date is the Friday after today; Add All to Reminders adds both. The recording is
    /// deleted again.
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
