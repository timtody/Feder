import XCTest

/// Naming speakers in a transcript: the name row's hit area, the rename sheet, the long-press menus (name row: Rename
/// Speaker…; text: the system's selection) and the notice while speakers are still being identified.
final class SpeakerNamingTests: ScribeUITestCase {

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
        XCTAssertTrue(field.appears(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5), "the name field is focused")
        dismissKeyboardTip(app)
        XCTAssertEqual(field.value as? String, "Anna Schmidt", "prefilled with the current name")
        // Lena too, below them: other tests' people (linked by voice in their recordings) can push her row out of the
        // half-height sheet, so she is looked for once typing filters the list (below).
        XCTAssertTrue(anna.exists && jonas.exists, "the known people are listed")
        XCTAssertLessThan(anna.frame.minY, jonas.frame.minY, "the speaker's own person first")
        shot("Rename sheet", app)

        field.typeText("Le")                                                   // replaces the selected name
        XCTAssertEqual(field.value as? String, "Le", "the prefilled name was selected")
        XCTAssertTrue(lena.appears(timeout: 3))
        XCTAssertFalse(anna.exists || jonas.exists, "typing filters the people")
        shot("Filtered", app)

        app.buttons["Clear Name"].tap()
        field.typeText("Maria Keller")
        app.buttons["SaveRename"].tap()
        XCTAssertTrue(field.disappears(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.0"].label, "Maria Keller")
        XCTAssertEqual(app.buttons["SpeakerHeader.2"].label, "Maria Keller", "both turns of the speaker renamed")
        XCTAssertEqual(app.buttons["SpeakerHeader.1"].label, "Jonas Weber", "the other speaker unchanged")
        shot("Typed name saved", app)

        app.buttons["SpeakerHeader.1"].tap()
        XCTAssertTrue(field.appears(timeout: 5))
        field.typeText("Le")                                                   // Lena's row, wherever the list puts it
        XCTAssertTrue(lena.appears(timeout: 5))
        lena.tap()
        XCTAssertTrue(field.disappears(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.1"].label, "Lena Vogel")
        XCTAssertEqual(app.buttons["SpeakerHeader.3"].label, "Lena Vogel", "both turns named as the chosen person")
        shot("Known person chosen", app)

        // Anna's fingerprint (her voice in Budget Review) is like this speaker's voice: offered right after Maria.
        app.buttons["SpeakerHeader.0"].tap()
        let maria = app.buttons["PersonChoice.Maria Keller"]
        XCTAssertTrue(maria.appears(timeout: 5))
        XCTAssertTrue(anna.label.contains("Similar voice"), anna.label)
        XCTAssertLessThan(maria.frame.minY, anna.frame.minY)
        if lena.exists {                                    // not in the tree: further down the sheet, after Anna too
            XCTAssertLessThan(anna.frame.minY, lena.frame.minY, "a similar voice before everyone else")
        }
        shot("Similar voice first", app)

        app.buttons["UseDefaultName"].tap()
        XCTAssertTrue(field.disappears(timeout: 5))
        XCTAssertEqual(app.buttons["SpeakerHeader.0"].label, "Speaker 1")
        XCTAssertEqual(app.buttons["SpeakerHeader.2"].label, "Speaker 1")
        shot("Default name", app)
    }

    /// The people's captions count their transcripts, read after the sheet's first frame, 16 transcripts per turn
    /// (FED-9). `-seedFiller 20`: twenty older transcripts come first (oldest first), so Budget Review, Lena Vogel's
    /// only one, is in the second batch; a count that stops after a batch, or never arrives, fails here. Anna Schmidt,
    /// the other speaker of Project Kickoff, reads "Already in this transcript" instead of a count.
    @MainActor
    func testRenameSheetCountsTranscripts() throws {
        let app = launch(["-seedFiller", "20"])
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.1"].tap()                                  // Jonas Weber
        let field = nameField(app)
        XCTAssertTrue(field.appears(timeout: 5))
        let anna = app.buttons["PersonChoice.Anna Schmidt"]
        XCTAssertTrue(anna.appears(timeout: 5))
        XCTAssertTrue(anna.label.hasSuffix("Already in this transcript"), "speaker 0 here: no count, \(anna.label)")
        field.typeText("Le")                                                   // Lena's row, wherever the list puts it
        let lena = app.buttons["PersonChoice.Lena Vogel"]
        XCTAssertTrue(lena.appears(timeout: 5))
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH ' 1 transcript'"), object: lena)
        XCTAssertEqual(XCTWaiter().wait(for: [counted], timeout: 5), .completed, "her one transcript, counted: \(lena.label)")
        shot("Transcripts counted", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(field.disappears(timeout: 5))
    }

    /// The captions' counts in German: "1 Transkript", "2 Transkripte" (FED-88: they stayed "1 transcript", built as a
    /// plain String). iOS 27 doesn't inflect German, so they come from the catalog's plural variation, as Settings ›
    /// People's do (FED-78): one and other both checked.
    @MainActor
    func testRenameSheetCountsInGerman() throws {
        let app = launch(["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-seedLicencePlanning"])
        checkCounts(app, one: "1 Transkript", other: "2 Transkripte", back: "Minimieren")
    }

    /// English's plural, "2 transcripts", which this view used to spell out itself and now gets from the inflection
    /// (FED-88). Budget Review's sheet only: testRenameSheetCountsTranscripts has the singular, so the second sheet
    /// would re-check it for 8 s more (20 s down to 12 s).
    @MainActor
    func testRenameSheetCountsPlural() throws {
        let app = launch(["-seedLicencePlanning"])
        checkCounts(app, one: nil, other: "2 transcripts", back: "Minimize")
    }

    /// `-seedLicencePlanning` gives Jonas Weber a second transcript: Budget Review's sheet shows him with two, Project
    /// Kickoff's Lena Vogel with one (that second sheet only with `one`). Not `open(_:in:)`: its checks look for the
    /// English labels. The field's focus is checked before each typing, so a sheet that never focuses it (seen once,
    /// FED-88's first run; not in 16 later tries with Budget Review's sheet the first after launch) fails as that, not
    /// as the typing after it.
    @MainActor
    private func checkCounts(_ app: XCUIApplication, one: String?, other: String, back: String) {
        let field = nameField(app)
        app.staticTexts["Budget Review"].firstMatch.tap()
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].appears(timeout: 10), "Budget Review opened")
        app.buttons["SpeakerHeader.0"].tap()                                  // Lena Vogel
        XCTAssertTrue(field.appears(timeout: 5))
        XCTAssertTrue(field.getsFocus(timeout: 5), "the name field is focused")
        field.typeText("Jo")
        let jonas = app.buttons["PersonChoice.Jonas Weber"]
        XCTAssertTrue(jonas.appears(timeout: 5))
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", " " + other), object: jonas)
        XCTAssertEqual(XCTWaiter().wait(for: [two], timeout: 5), .completed, "his two transcripts: \(jonas.label)")
        shot("Two transcripts", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(field.disappears(timeout: 5))
        guard let one else { return }

        app.buttons[back].tap()                                               // the card's back button
        // Closed before the next tap: Budget Review has a SpeakerHeader.1 too (Anna Schmidt), whose sheet would fail
        // as Lena's caption. The title field's value, not its label, which is "Titel" in German.
        XCTAssertTrue(app.buttons[back].disappears(timeout: 5), "Budget Review's card closed")
        app.staticTexts["Project Kickoff"].firstMatch.tap()
        let kickoff = app.textFields.matching(NSPredicate(format: "value == %@", "Project Kickoff")).firstMatch
        XCTAssertTrue(kickoff.appears(timeout: 10), "Project Kickoff opened")
        XCTAssertTrue(app.buttons["SpeakerHeader.1"].appears(timeout: 10), "its speakers")
        app.buttons["SpeakerHeader.1"].tap()                                  // Jonas Weber
        XCTAssertTrue(field.appears(timeout: 5))
        XCTAssertTrue(field.getsFocus(timeout: 5), "the name field is focused")
        field.typeText("Le")
        let lena = app.buttons["PersonChoice.Lena Vogel"]
        XCTAssertTrue(lena.appears(timeout: 5))
        let single = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", " " + one), object: lena)
        XCTAssertEqual(XCTWaiter().wait(for: [single], timeout: 5), .completed, "her one transcript: \(lena.label)")
        shot("One transcript", app)
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(field.disappears(timeout: 5))
    }

    /// Long-pressing a name row offers "Rename Speaker…" (the sheet for that speaker); long-pressing a paragraph keeps
    /// the system's text selection: its edit menu, whose Copy is pasted into the Add Tag field to check.
    @MainActor
    func testLongPressMenusKeepTextSelection() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.2)
        let rename = app.buttons["Rename Speaker…"]
        XCTAssertTrue(rename.appears(timeout: 5), "the name row's menu offers Rename Speaker…")
        shot("Name row menu", app)
        rename.tap()
        XCTAssertTrue(nameField(app).appears(timeout: 5))
        XCTAssertEqual(nameField(app).value as? String, "Jonas Weber", "the sheet is for that row's speaker")
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).disappears(timeout: 5))
        RunLoop.current.run(until: .now + 1)                                   // the sheet has gone

        let paragraph = app.staticTexts["Paragraph.0"]
        paragraph.press(forDuration: 1.2)
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.appears(timeout: 5), "the paragraph's text selection menu")
        XCTAssertFalse(rename.exists, "no rename menu over the text")
        shot("Text selection menu", app)
        copy.tap()
        tapMenuItem("Add Tag", in: app)                                      // the tag line, with its field
        let tagField = app.textFields["Add Tag"]
        XCTAssertTrue(tagField.appears(timeout: 5))
        tagField.tap()
        tagField.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.appears(timeout: 5), "the edit menu offers Paste")
        paste.tap()
        _ = waitFor { !["", "Add Tag"].contains(tagField.value as? String ?? "") }   // the paste lands a moment later
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
        XCTAssertTrue(sync.appears(timeout: 10))
        sync.tap()
        let header = app.buttons["SpeakerHeader.0"]
        XCTAssertTrue(header.appears(timeout: 10))
        header.tap()
        let notice = app.descendants(matching: .any)["SpeakerNotice"]
        XCTAssertTrue(notice.appears(timeout: 3), "the notice shows")
        XCTAssertFalse(nameField(app).exists, "no sheet")
        shot("Preliminary notice", app)
        XCTAssertTrue(notice.disappears(timeout: 8), "the notice goes away by itself")

        header.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Rename Speaker…"].appears(timeout: 2), "no renaming before speakers are final")
        shot("Preliminary long press", app)
    }

    /// The first transcript with final speakers, all still "Speaker N", shows a tip on the first name row that names
    /// are tappable (TipKit; `-showTips -resetTips`, the other tests hide tips). Tapping the name opens the rename
    /// sheet and ends the tip; the tap takes the tip's popover away itself (FED-9).
    @MainActor
    func testNameSpeakersTip() throws {
        let app = launch(["-showTips", "-resetTips", "-autoRecord", "-autoStopAfter", "4"])
        XCTAssertTrue(app.buttons["Delete Transcript"].appears(timeout: 25), "saved: the card shows the transcript")
        let tip = app.staticTexts["Name the Speakers"]
        XCTAssertTrue(tip.appears(timeout: 15), "the tip once the speakers are final")
        sleep(1)                                            // its fade-in
        shot("Name the speakers tip", app)
        let header = app.buttons["SpeakerHeader.0"]
        let below = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Tap a speaker'")).firstMatch
        XCTAssertTrue(below.exists, "it says what to do")
        XCTAssertLessThan(header.frame.minY, tip.frame.minY, "under the first name, pointing at it")
        sleep(1)                                            // the keyboard's warm-up has run (KeyboardWarmup)
        XCTAssertTrue(tip.exists, "the warm-up leaves the tip up")
        // Keys left up are in the tree even off-screen behind the hardware keyboard, so a warm-up that leaves its field
        // holding the keys fails here (taking out only the resign or only the removal doesn't: either gives them back).
        // It can't see a flash (README › Performance, Rename); the ", keyboard warmed up" marker below shows it ran.
        XCTAssertEqual(app.keyboards.count, 0, "the warm-up gave the keys back")
        // One tap: the tip lets taps through to the page (tipBackgroundInteraction), so the name renames at once.
        header.tap()
        let cancel = app.buttons["CancelRename"]
        XCTAssertTrue(cancel.appears(timeout: 5), "the rename sheet on the first tap")
        // The tip is gone once the sheet is up, and SwiftUI, which presented the tip's popover, doesn't take the sheet
        // along when it lets go of the popover.
        XCTAssertFalse(tip.exists, "and the tip is gone")
        sleep(1)
        XCTAssertTrue(cancel.exists, "the sheet stays")
        cancel.tap()
        XCTAssertTrue(cancel.disappears(timeout: 5))
        // The tap found the tip's popover and UIKit took it away without its animation: NameSpeakersTip's
        // closePopoverAtOnce says so in the first name row's value (DEBUG, `-showTips`), so an iOS that presents the tip
        // otherwise fails here. How soon the sheet then moves is not checked: XCUITest can't time it (README ›
        // Performance, Rename).
        // The keyboard was set up while the tip was up, not by the tap (KeyboardWarmup).
        XCTAssertEqual(header.value as? String, "Tip popover closed at once, keyboard warmed up",
                       "the tap took the tip's popover away")

        // Debug builds: Settings › About › Reset Onboarding brings it back at once, without a relaunch.
        closeCard(app)
        app.buttons["Settings"].firstMatch.tap()
        let reset = app.buttons["Reset Onboarding"].firstMatch
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        XCTAssertTrue(app.staticTexts["Welcome to Feder"].appears(timeout: 5))
        app.buttons["Continue"].tap()
        app.buttons["Continue"].tap()
        app.buttons["No Thanks"].tap()
        XCTAssertTrue(app.buttons["Show in iPhone Search"].appears(timeout: 5))
        app.buttons["No Thanks"].tap()
        if app.buttons["Not Now"].appears(timeout: 3) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.staticTexts["Welcome to Feder"].disappears(timeout: 5))
        let transcripts = app.buttons["Transcripts"].firstMatch
        for _ in 0..<4 where !transcripts.exists { app.swipeDown() }     // Settings scrolled: the bar minimized
        transcripts.tap()
        // The transcript just recorded (its speakers still unnamed), the newest row.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'New Transcript'")).firstMatch.tap()
        XCTAssertTrue(tip.appears(timeout: 10), "the tip again after Reset Onboarding")

        // The recording goes again: left behind, every run added a row above the seeded transcripts, until the list
        // tests no longer found "Budget Review" or "Archive 1" on the first screen.
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "deleted: the card closed")
    }
}

/// The name row's hit area (SpeakerNamingTests' slowest part, a class of its own so a parallel run gives it a worker
/// while the others run).
final class NameRowHitAreaTests: ScribeUITestCase {
    /// Taps points around the first two name rows of "Project Kickoff": every point of a row (from the paragraph above,
    /// so the whole gap above the name, down to the text; at its left, middle and right) must open the rename sheet, no
    /// point on a line of paragraph text may. The text of paragraph n lies between name rows n and n + 1 (on iOS 27 a
    /// selectable text's accessibility frame is 16 pt larger than its text, so it is not used). The row is as wide as
    /// the name and its time, not the whole width: a tap right of it does nothing. Points every 14 pt and at the row's
    /// edges (every 6 pt until October 2026, and points just outside a row that were only recorded: 111 taps, 7.4
    /// minutes); the map is attached as "Hit map".
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
            XCTAssertLessThan(row.width, 220, "about the name and its time: \(row)")

            let inRow = Array(stride(from: row.minY + 2, through: row.maxY - 2, by: 14))
                + [name.minY - 12, name.midY, row.maxY - 2, row.maxY - 1]
            var onText = [row.maxY + 11, (row.maxY + textBottom) / 2, textBottom - 11]   // first, middle, last line
            if index > 0 { onText.append(row.minY - 11) }                      // the last line of the text above
            for (kind, ys) in [("row ", inRow), ("text", onText)] {
                for y in Set(ys).sorted() {
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
            if index == 0 {
                XCTAssertFalse(tapOpensSheet(app, x: app.frame.maxX - 40, y: name.midY), "the right of the row does nothing")
            }
        }
        note("Hit map", map)
        XCTAssertEqual(wrong, [], "taps that opened the sheet on text, or did not in a name row")
    }

    /// Taps one point; reports whether the rename sheet opened (and closes it again). The sheet is up within ~0.4 s of
    /// a tap that opens it, so 1.5 s is ample for one that doesn't (2.5 s until October 2026).
    @MainActor
    private func tapOpensSheet(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> Bool {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
        guard nameField(app).appears(timeout: 1.5) else { return false }
        app.buttons["CancelRename"].tap()
        XCTAssertTrue(nameField(app).disappears(timeout: 5))
        return true
    }
}
