import XCTest

/// Naming speakers in a transcript: the name row's hit area, the rename sheet, the long-press menus (name row: Rename
/// Speaker…; text: the system's selection) and the notice while speakers are still being identified.
final class SpeakerNamingTests: ScribeUITestCase {

    /// Taps a grid of points around the first two name rows of "Project Kickoff": every point of a row (full width,
    /// from the paragraph above, so the whole gap above the name, down to the text) must open the rename sheet, no
    /// point on a line of paragraph text may. The text of paragraph n lies between name rows n and n + 1 (on iOS 27 a
    /// selectable text's accessibility frame is 16 pt larger than its text, so it is not used). Points 2 and 6 pt
    /// outside a row are only recorded (where no text is, SwiftUI gives a touch near a button to it). The map is
    /// attached as "Hit map".
    @MainActor
    func testNameRowHitArea() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        shot("Transcript", app)
        var map = ""
        var wrong: [String] = []
        for index in [0, 1] {
            let header = app.buttons["SpeakerHeader.\(index)"]
            let row = header.frame
            let name = header.staticTexts.firstMatch.frame                       // the name, in the row's last line
            let textBottom = app.buttons["SpeakerHeader.\(index + 1)"].frame.minY
            map += "Name row \(index): \(row), name \(name), its text \(row.maxY)-\(textBottom)\n"
            XCTAssertGreaterThanOrEqual(row.height, 56, "name row \(index) is at least 56 pt tall")
            XCTAssertGreaterThanOrEqual(name.minY - row.minY, 30, "the gap above name \(index) belongs to its row")
            XCTAssertEqual(row.maxY, name.maxY + 4, accuracy: 1.5, "name row \(index) reaches down to its text")

            let inRow = Array(stride(from: row.minY + 2, through: row.maxY - 2, by: 6))
                + [name.minY - 12, name.midY, row.maxY - 1]
            var onText = [row.maxY + 11, (row.maxY + textBottom) / 2, textBottom - 11]   // first, middle, last line
            if index > 0 { onText.append(row.minY - 11) }                      // the last line of the text above
            let edges = [2.0, 6].map { row.maxY + $0 } + (index > 0 ? [2.0, 6].map { row.minY - $0 } : [])
            for (kind, ys) in [("row ", inRow), ("text", onText), ("edge", edges)] {
                for y in ys.sorted() {
                    for x in [row.minX + 4, row.midX, row.maxX - 4] {
                        let opens = tapOpensSheet(app, x: x, y: y)
                        let line = String(format: "  %@ y %+4.0f from name top, x %3.0f: %@", kind, y - name.minY, x,
                                          opens ? "opens" : "nothing")
                        let isWrong = (kind == "row " && !opens) || (kind == "text" && opens)
                        map += line + (isWrong ? "   <- WRONG\n" : "\n")
                        if isWrong { wrong.append("row \(index)" + line) }
                    }
                }
            }
        }
        note("Hit map", map)
        XCTAssertEqual(wrong, [], "taps that opened the sheet on text, or did not in a name row")
    }

    /// Typing a name names every turn of that speaker; the people list filters as you type; choosing a known person
    /// names the speaker as that person; a person with a similar voice is offered first; "Use Default Name" resets.
    @MainActor
    func testRenameSheet() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        let field = nameField(app)
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        let jonas = app.buttons["PersonChoice.Jonas Weber"]
        let lena = app.buttons["PersonChoice.Lena Vogel"]

        app.buttons["SpeakerHeader.0"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the name field is focused")
        dismissKeyboardTip(app)
        XCTAssertEqual(field.value as? String, "Anna Schmidt", "prefilled with the current name")
        // Lena too, below them: other tests' people (linked by voice in their recordings) can push her row out of the
        // half-height sheet, so she is looked for once typing filters the list (below).
        XCTAssertTrue(anna.exists && jonas.exists, "the known people are listed")
        XCTAssertLessThan(anna.frame.minY, jonas.frame.minY, "the speaker's own person first")
        shot("Rename sheet", app)

        field.typeText("Le")                                                   // replaces the selected name
        XCTAssertEqual(field.value as? String, "Le", "the prefilled name was selected")
        XCTAssertTrue(lena.waitForExistence(timeout: 3))
        XCTAssertFalse(anna.exists || jonas.exists, "typing filters the people")
        shot("Filtered", app)

        app.buttons["Clear Name"].tap()
        field.typeText("Maria Keller")
        app.buttons["SaveRename"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.0"].label, "Maria Keller")
        XCTAssertEqual(app.buttons["SpeakerHeader.2"].label, "Maria Keller", "both turns of the speaker renamed")
        XCTAssertEqual(app.buttons["SpeakerHeader.1"].label, "Jonas Weber", "the other speaker unchanged")
        shot("Typed name saved", app)

        app.buttons["SpeakerHeader.1"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Le")                                                   // Lena's row, wherever the list puts it
        XCTAssertTrue(lena.waitForExistence(timeout: 5))
        lena.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.1"].label, "Lena Vogel")
        XCTAssertEqual(app.buttons["SpeakerHeader.3"].label, "Lena Vogel", "both turns named as the chosen person")
        shot("Known person chosen", app)

        // Anna's fingerprint (her voice in Budget Review) is like this speaker's voice: offered right after Maria.
        app.buttons["SpeakerHeader.0"].tap()
        let maria = app.buttons["PersonChoice.Maria Keller"]
        XCTAssertTrue(maria.waitForExistence(timeout: 5))
        XCTAssertTrue(anna.label.contains("Similar voice"), anna.label)
        XCTAssertLessThan(maria.frame.minY, anna.frame.minY)
        if lena.exists {                                    // not in the tree: further down the sheet, after Anna too
            XCTAssertLessThan(anna.frame.minY, lena.frame.minY, "a similar voice before everyone else")
        }
        shot("Similar voice first", app)

        app.buttons["UseDefaultName"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.0"].label, "Speaker 1")
        XCTAssertEqual(app.buttons["SpeakerHeader.2"].label, "Speaker 1")
        shot("Default name", app)
    }

    /// Long-pressing a name row offers "Rename Speaker…" (the sheet for that speaker); long-pressing a paragraph keeps
    /// the system's text selection: its edit menu, whose Copy is pasted into the Add Tag field to check.
    @MainActor
    func testLongPressMenusKeepTextSelection() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.2)
        let rename = app.buttons["Rename Speaker…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the name row's menu offers Rename Speaker…")
        shot("Name row menu", app)
        rename.tap()
        XCTAssertTrue(nameField(app).waitForExistence(timeout: 5))
        XCTAssertEqual(nameField(app).value as? String, "Jonas Weber", "the sheet is for that row's speaker")
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).waitForNonExistence(timeout: 5))
        RunLoop.current.run(until: .now + 1)                                   // the sheet has gone

        let paragraph = app.staticTexts["Paragraph.0"]
        paragraph.press(forDuration: 1.2)
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the paragraph's text selection menu")
        XCTAssertFalse(rename.exists, "no rename menu over the text")
        shot("Text selection menu", app)
        copy.tap()
        app.buttons["Add Tag"].tap()                                          // the tag line, with its field
        let tagField = app.textFields["Add Tag"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5))
        tagField.tap()
        tagField.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the edit menu offers Paste")
        paste.tap()
        let pasted = tagField.value as? String ?? ""
        XCTAssertFalse(pasted.isEmpty || pasted == "Add Tag", "something was copied")
        XCTAssertTrue(paragraph.label.contains(pasted), "Copy copied (part of) the paragraph: \(pasted)")
        shot("Copied text pasted", app)
    }

    /// While speakers are still being identified, a tap on a name shows a short notice instead of the sheet, and its
    /// long-press offers no renaming.
    @MainActor
    func testPreliminaryNameShowsNotice() throws {
        let app = launch(["-seedPendingSample", "-fakeDiarizeSeconds", "600"])
        let sync = app.staticTexts["Weekly Sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10))
        sync.tap()
        let header = app.buttons["SpeakerHeader.0"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.tap()
        let notice = app.descendants(matching: .any)["SpeakerNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 3), "the notice shows")
        XCTAssertFalse(nameField(app).exists, "no sheet")
        shot("Preliminary notice", app)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 8), "the notice goes away by itself")

        header.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Rename Speaker…"].waitForExistence(timeout: 2), "no renaming before speakers are final")
        shot("Preliminary long press", app)
    }

    /// Taps one point; reports whether the rename sheet opened (and closes it again).
    @MainActor
    private func tapOpensSheet(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> Bool {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
        guard nameField(app).waitForExistence(timeout: 2.5) else { return false }
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).waitForNonExistence(timeout: 5))
        return true
    }

    /// The first transcript with final speakers, all still "Speaker N", shows a tip on the first name row that names
    /// are tappable (TipKit; `-showTips -resetTips`, the other tests hide tips). Tapping the name opens the rename
    /// sheet and ends the tip.
    @MainActor
    func testNameSpeakersTip() throws {
        let app = launch(["-showTips", "-resetTips", "-autoRecord", "-autoStopAfter", "4"])
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 25), "saved: the card shows the transcript")
        let tip = app.staticTexts["Name the Speakers"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15), "the tip once the speakers are final")
        sleep(1)                                            // its fade-in
        shot("Name the speakers tip", app)
        let header = app.buttons["SpeakerHeader.0"]
        let below = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Tap a speaker'")).firstMatch
        XCTAssertTrue(below.exists, "it says what to do")
        XCTAssertLessThan(header.frame.minY, tip.frame.minY, "under the first name, pointing at it")
        // One tap: the tip lets taps through to the page (tipBackgroundInteraction), so the name renames at once.
        header.tap()
        let cancel = app.buttons["CancelRename"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the rename sheet on the first tap")
        XCTAssertTrue(tip.waitForNonExistence(timeout: 5), "and the tip is gone")

        // Debug builds: Settings › About › Reset Onboarding brings it back at once, without a relaunch.
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        closeCard(app)
        app.buttons["Settings"].firstMatch.tap()
        let reset = app.buttons["Reset Onboarding"].firstMatch
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        XCTAssertTrue(app.staticTexts["Welcome to Feder"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        app.buttons["Continue"].tap()
        app.buttons["No Thanks"].tap()
        XCTAssertTrue(app.buttons["Show in iPhone Search"].waitForExistence(timeout: 5))
        app.buttons["No Thanks"].tap()
        XCTAssertTrue(app.buttons["Name from Calendar"].waitForExistence(timeout: 5))
        app.buttons["No Thanks"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.staticTexts["Welcome to Feder"].waitForNonExistence(timeout: 5))
        let transcripts = app.buttons["Transcripts"].firstMatch
        for _ in 0..<4 where !transcripts.exists { app.swipeDown() }     // Settings scrolled: the bar minimized
        transcripts.tap()
        // The transcript just recorded (its speakers still unnamed), the newest row.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript'")).firstMatch.tap()
        XCTAssertTrue(tip.waitForExistence(timeout: 10), "the tip again after Reset Onboarding")
    }

    /// The name row's button is as wide as the name and its time (plus a little room), not the whole width: a tap on
    /// the name renames, a tap at the right of the row does nothing.
    @MainActor
    func testNameRowIsNarrow() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        let header = app.buttons["SpeakerHeader.0"]
        let row = header.frame
        let name = header.staticTexts.firstMatch.frame
        XCTAssertLessThan(row.width, 220, "about the name and its time: \(row)")
        XCTAssertGreaterThanOrEqual(row.height, 56, "still tall enough to hit")
        XCTAssertTrue(tapOpensSheet(app, x: name.midX, y: name.midY), "the name renames")
        XCTAssertFalse(tapOpensSheet(app, x: app.frame.maxX - 40, y: name.midY), "the right of the row does nothing")
    }
}
