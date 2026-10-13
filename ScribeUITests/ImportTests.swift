import XCTest

/// Importing audio (AudioImporter): the record accessory's Import button, and a file that becomes a transcript.
final class ImportTests: ScribeUITestCase {
    /// Import sits at the accessory's end, right of the language; minimized, Import stays and the language goes. A tap
    /// opens the system's file picker.
    @MainActor
    func testImportButtonPlacementAndPicker() throws {
        let app = launch(["-seedFiller", "12"])
        let importButton = app.buttons["ImportAudio"]
        let language = app.buttons["Language"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5), "Import in the accessory")
        XCTAssertTrue(language.exists)
        XCTAssertGreaterThan(importButton.frame.minX, language.frame.maxX - 1, "right of the language")
        XCTAssertLessThan(abs(importButton.frame.midY - language.frame.midY), 3, "on the language's line")
        shot("Accessory with Import", app)

        app.swipeUp()                                            // the list scrolls: the bar minimizes
        XCTAssertTrue(waitFor { !language.isHittable }, "minimized: no language")
        XCTAssertTrue(importButton.isHittable, "Import is still there")
        XCTAssertGreaterThan(importButton.frame.midX, app.frame.width * 0.5, "on the right")
        shot("Minimized with Import", app)

        // The system's file picker runs in its own process (its buttons aren't in the app's tree): it covers the app.
        importButton.tap()
        XCTAssertTrue(waitFor({ !importButton.isHittable }, timeout: 10), "the file picker covers the app")
        shot("File picker", app)
        // A swipe down closes it; one fast swipe sometimes didn't take while the sheet was still settling (full suite).
        for _ in 0..<3 where !importButton.isHittable {
            app.swipeDown(velocity: .fast)
            _ = waitFor({ importButton.isHittable }, timeout: 4)
        }
        XCTAssertTrue(importButton.isHittable, "and goes again")
    }

    /// A file shared from another app (`-importTestAudio`: a 12 s AAC file, "Interview Lena", made a month ago) becomes
    /// a transcript: the card opens on it, its words and speakers come in, and it can be listened to (its audio is
    /// kept). It is dated when it was imported, not by its file, so it tops the list, and it is tagged Import (FED-6).
    @MainActor
    func testImportedFileBecomesTranscript() throws {
        let app = launch(["-importTestAudio", "-fakeWordChanges", "-fakeDiarizeSeconds", "1"])
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the card on the imported transcript")
        XCTAssertEqual(title.value as? String, "Interview Lena", "named after the file")
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].waitForExistence(timeout: 20), "its words and speakers")
        XCTAssertTrue(app.buttons["Listen"].wait(for: \.isEnabled, toEqual: true, timeout: 5), "and its audio")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0:12'")).firstMatch.exists,
                      "its length")
        // The card's date line, under the title: the rows behind the card have dates in the tree too.
        let titleFrame = title.frame
        let dated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today at '")).allElementsBoundByIndex
            .contains { abs($0.frame.minY - titleFrame.maxY) < 30 && $0.isHittable }
        XCTAssertTrue(dated, "dated today, not a month ago as its file")
        XCTAssertTrue(app.buttons["Remove Import"].exists, "tagged Import")
        shot("Imported", app)

        closeCard(app)
        let meta = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Today at' AND label CONTAINS 'Tag: Import'")).firstMatch
        XCTAssertTrue(meta.waitForExistence(timeout: 5), "its row: today, with the Import tag")
        let row = app.staticTexts["Interview Lena"].firstMatch
        XCTAssertLessThan(row.frame.minY, app.staticTexts["Project Kickoff"].firstMatch.frame.minY,
                          "on top of the list, above the newest sample")
        shot("Imported in the list", app)

        row.tap()
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 5))
        app.buttons["Delete Transcript"].tap()                   // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
    }

    /// An import's action items count their deadlines from the day its file says it was recorded (`originalDate`), not
    /// from the import, which dates the transcript (FED-6): last month's "by Friday" is last month's Friday.
    /// `-fakeGemma`: FakeTextWriter answers "by Friday" and "tomorrow at 10:00", so the first is due the Friday after the
    /// file's day (30 days before the launch, `makeTestAudio`), the second at 10:00 the day after it. Counted from the
    /// import, both were in the coming days. The import is deleted again.
    @MainActor
    func testImportDeadlinesCountFromTheFileDate() throws {
        let app = launch(["-importTestAudio", "-fakeGemma", "-fakeWordChanges", "-fakeDiarizeSeconds", "1"])
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the card on the imported transcript")
        XCTAssertEqual(title.value as? String, "Interview Lena", "named after the file")
        let button = app.buttons["Action Items"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the Action Items button")
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 30), "once the speakers are final")
        button.tap()
        let first = app.descendants(matching: .any)["ActionItem.0"].firstMatch
        let second = app.descendants(matching: .any)["ActionItem.1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30) && second.exists, "the items found")
        XCTAssertTrue(first.label.contains("Send the test results to the team"), first.label)

        // The dates as the sheet writes them (ActionItemText.due: the app's language, the region's formats).
        let calendar = Calendar.current
        let filed = calendar.startOfDay(for: .now.addingTimeInterval(-30 * 86_400))
        let friday = next(6, after: filed)
        let tomorrow = calendar.date(bySettingHour: 10, minute: 0, second: 0,
                                     of: calendar.date(byAdding: .day, value: 1, to: filed)!)!
        func shown(_ date: Date, time: Bool) -> String {
            let locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
            var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)
            if !calendar.isDate(date, equalTo: .now, toGranularity: .year) { style = style.year() }
            if time { style = style.hour().minute() }
            return date.formatted(style)
        }
        XCTAssertTrue(first.label.contains(shown(friday, time: false)),
                      "due the Friday after the file's day, \(shown(friday, time: false)): \(first.label)")
        XCTAssertTrue(second.label.contains(shown(tomorrow, time: true)),
                      "due the day after the file's day, \(shown(tomorrow, time: true)): \(second.label)")
        shot("Imported action items", app)

        app.buttons["CloseActionItems"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5), "the sheet closed")
        app.buttons["Delete Transcript"].tap()                   // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
    }

    /// A second file shared while the first is converting waits its turn: both become transcripts, and the card opens
    /// on the last one. (Dropped, the second was lost without a word.)
    @MainActor
    func testFileSharedDuringAnImportWaitsItsTurn() throws {
        let app = launch(["-importTestAudio", "-importTwoFiles", "-fakeWordChanges", "-fakeDiarizeSeconds", "1"])
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the card")
        XCTAssertEqual(title.value as? String, "Interview Max", "on the last file")
        app.buttons["Delete Transcript"].tap()                   // the samples stay on top for the other tests
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
        let first = app.staticTexts["Interview Lena"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the first file is a transcript too")
        XCTAssertLessThan(first.frame.minY, app.staticTexts["Project Kickoff"].firstMatch.frame.minY,
                          "on top of the list too")
        first.tap()
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 5))
        app.buttons["Delete Transcript"].tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
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
