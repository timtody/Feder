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
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor({ importButton.isHittable }, timeout: 10), "and goes again")
    }

    /// A file shared from another app (`-importTestAudio`: a 12 s AAC file, "Interview Lena") becomes a transcript:
    /// the card opens on it, its words and speakers come in, and it can be listened to (its audio is kept).
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
        shot("Imported", app)
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
