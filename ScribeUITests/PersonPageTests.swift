import XCTest

/// A person's page (the Phone app's contact card: name as the large title, Last Conversation, Voice Profile, their
/// transcripts with what they said), opened from Settings › People or with "Go to Person" from a card's name row, which
/// closes the card and pushes the page onto the tab under it (Apple Music's Go to Artist).
final class PersonPageTests: ScribeUITestCase {

    /// Settings › People › Anna Schmidt: her name as the title, when you last spoke, her voice profile (saved: she was
    /// named where a voice is stored), her two transcripts each with her longest turn quoted; a row opens the card at that turn ("1 of 2" through her turns, the turn marked), and
    /// closing it comes back to her page.
    @MainActor
    func testPersonPageShowsWhatTheySaid() throws {
        let app = launch()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["People"].tap()
        XCTAssertTrue(app.navigationBars["People"].appears(timeout: 5), "People pushed inside Settings")
        app.staticTexts["Anna Schmidt"].tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].appears(timeout: 5), "her page, her name as the title")

        let last = app.descendants(matching: .any)["LastConversation"]
        XCTAssertTrue(last.appears(timeout: 5), "the Last Conversation row")
        XCTAssertTrue(last.label.contains("Last Conversation")
                      && dayWords(since: launchedAt).contains { last.label.contains("\($0) at") },
                      "Project Kickoff is today: \(last.label)")
        XCTAssertTrue(app.staticTexts["2 Transcripts"].exists, "the transcripts' header")
        let profile = app.descendants(matching: .any)["VoiceProfile"]
        XCTAssertTrue(profile.exists && profile.label.contains("Voice Profile") && (profile.value as? String) == "Saved"
                        && !profile.label.contains("Not Saved"), "her voice profile: \(profile.label) \(profile.value ?? "")")
        XCTAssertTrue(last.frame.maxY <= profile.frame.minY && profile.frame.maxY <= app.staticTexts["2 Transcripts"].frame.minY,
                      "between Last Conversation and her transcripts")
        XCTAssertTrue(app.buttons["DeleteVoiceProfile"].exists, "and the button to delete it")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists && app.staticTexts["Budget Review"].exists,
                      "her transcripts are listed")
        // Her longest turn in each: Budget Review's first one, Project Kickoff's second.
        let budgetQuote = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
        XCTAssertTrue(budgetQuote.appears(timeout: 10), "what she said in Budget Review")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Agreed. If we cut playback'"))
                        .firstMatch.exists, "what she said in Project Kickoff")
        shot("Person page", app)
        // The separator between her transcripts starts at their text, inside the card (FED-74).
        assertSeparatorStartsAtText(under: "Project Kickoff", app)

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        XCTAssertTrue(app.staticTexts["Match 1 of 2"].appears(timeout: 5), "n of m through her turns")
        XCTAssertEqual(app.staticTexts["Paragraph.1"].value as? String, "Current match", "the quoted turn is marked")
        shot("Card at her turn", app)
        app.buttons["Next Match"].tap()
        XCTAssertTrue(app.staticTexts["Match 2 of 2"].appears(timeout: 5), "her second turn")
        closeCard(app)
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].appears(timeout: 5), "back on her page")
    }

    /// Delete Voice Profile on her page (the fingerprint button): it asks first, Cancel keeps it; Delete turns the row to
    /// "Not Saved", the button goes and the footer says how to save one again; People then reads "voice not known yet"
    /// for her only. Her voice is gone from her transcripts too: naming her again in Project Kickoff (renamed away and
    /// back, as typed) saves no new profile there.
    @MainActor
    func testDeleteVoiceProfileOnPage() throws {
        let app = launch(["-showPerson", "Anna Schmidt"])
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.appears(timeout: 10), "her page")
        let profile = app.descendants(matching: .any)["VoiceProfile"]
        XCTAssertTrue(profile.appears(timeout: 5) && (profile.value as? String) == "Saved"
                        && !profile.label.contains("Not Saved"), profile.label)
        let delete = app.buttons["DeleteVoiceProfile"]
        XCTAssertTrue(delete.exists && delete.label.contains("Delete Voice Profile"), delete.label)
        shot("Voice profile saved", app)

        delete.tap()
        let title = app.staticTexts["Delete Voice Profile of Anna Schmidt?"]
        XCTAssertTrue(title.appears(timeout: 5), "asks first")
        shot("Delete voice profile dialog", app)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { page.tap() }   // a popover has no Cancel
        XCTAssertTrue(title.disappears(timeout: 5))
        XCTAssertFalse(profile.label.contains("Not Saved"), "Cancel keeps it")

        delete.tap()
        XCTAssertTrue(title.appears(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label == 'Delete Voice Profile' AND identifier != 'DeleteVoiceProfile'"))
            .firstMatch.tap()
        XCTAssertTrue(waitFor { profile.label.contains("Not Saved") }, "the row: \(profile.label)")
        XCTAssertTrue(delete.disappears(timeout: 5), "nothing left to delete")
        XCTAssertTrue(app.staticTexts["Name Anna Schmidt in a new transcript to save their voice and recognize them in later recordings."].exists,
                      "the footer says how to save one again")
        shot("Voice profile deleted", app)

        page.buttons.firstMatch.tap()                                    // Back to People
        XCTAssertTrue(app.navigationBars["People"].appears(timeout: 5))
        let unknown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'voice not known yet'"))
        XCTAssertTrue(unknown.firstMatch.appears(timeout: 5))
        XCTAssertEqual(unknown.count, 1, "only Anna's voice is unknown")
        XCTAssertEqual(unknown.firstMatch.label, "2 transcripts · voice not known yet", "Anna's row (Lena and Jonas have one)")

        // Renamed away and back in Project Kickoff: her voice there was removed, so no new profile.
        app.buttons["Transcripts"].firstMatch.tap()
        open("Project Kickoff", in: app)
        rename(speaker: 0, to: "Maria Keller", app)
        rename(speaker: 0, to: "Anna Schmidt", app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)
        app.buttons["Go to Person"].tap()
        XCTAssertTrue(page.appears(timeout: 10), "her page")
        XCTAssertTrue(profile.appears(timeout: 5) && profile.label.contains("Not Saved"), profile.label)
    }

    /// With Recognize People by Voice off (a new install's state) nobody has a profile: her page has no Voice Profile
    /// section, as People's rows say nothing about voices.
    @MainActor
    func testVoiceProfileHiddenWithRecognitionOff() throws {
        let app = launch(["-resetVoiceRecognition", "-showPerson", "Anna Schmidt"])
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].appears(timeout: 10), "her page")
        XCTAssertTrue(app.descendants(matching: .any)["LastConversation"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["VoiceProfile"].exists, "no Voice Profile")
        XCTAssertFalse(app.buttons["DeleteVoiceProfile"].exists)
    }

    @MainActor
    private func rename(speaker: Int, to name: String, _ app: XCUIApplication) {
        app.buttons["SpeakerHeader.\(speaker)"].press(forDuration: 1.0)
        app.buttons["Rename Speaker…"].tap()
        let field = nameField(app)
        XCTAssertTrue(field.appears(timeout: 5))
        dismissKeyboardTip(app)
        app.buttons["Clear Name"].tap()
        field.typeText(name)
        app.buttons["SaveRename"].tap()
        XCTAssertTrue(field.disappears(timeout: 5))
        XCTAssertTrue(waitFor { app.buttons["SpeakerHeader.\(speaker)"].label == name }, "renamed \(name)")
    }


    /// `-seedLicencePlanning` (a third transcript of Anna's), at Larger Text's largest standard size (the page then
    /// scrolls on any iPhone): scrolled, the large title collapses into the bar, as in Contacts. Opened again from
    /// People, her page has its quotes at once (the last ones shown, then brought up to date), not placeholders filled
    /// in after the push.
    @MainActor
    func testPersonPageTitleCollapsesAndKeepsQuotes() throws {
        let app = launch(["-seedLicencePlanning", "-showPerson", "Anna Schmidt",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.appears(timeout: 10), "her page")
        XCTAssertTrue(app.staticTexts["3 Transcripts"].appears(timeout: 5))
        let quote = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
        XCTAssertTrue(quote.appears(timeout: 10), "her quotes")

        let large = page.frame.height
        app.swipeUp()
        let end = Date.now.addingTimeInterval(3)
        while Date.now < end, page.frame.height > large - 20 { RunLoop.current.run(until: .now + 0.2) }
        note("Navigation bar", "large \(large), scrolled \(page.frame.height)")
        shot("Person page scrolled", app)
        XCTAssertLessThan(page.frame.height, large - 20, "the title collapsed into the bar")
        app.swipeDown()

        page.buttons.firstMatch.tap()                                    // Back to People
        XCTAssertTrue(app.navigationBars["People"].appears(timeout: 5))
        app.staticTexts["Anna Schmidt"].tap()
        XCTAssertTrue(page.appears(timeout: 5))
        XCTAssertTrue(quote.exists, "her quotes, with the page")
    }

    /// A tag in a row of her page in the Search tab (Go to Person from a result's card): the fresh search (her and the
    /// tag) replaces the one her page was over, and Close comes back to her page, whose Back leads to that earlier
    /// search; its Close then leaves Search for the tab it was opened from.
    @MainActor
    func testTagOnPageInSearchTab() throws {
        let app = launch(["-seedLicencePlanning"])
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.appears(timeout: 10), "the Search tab")
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5), "the field has the focus")
        dismissKeyboardTip(app)
        app.typeText("budget")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].disappears(timeout: 10), "the results")
        XCTAssertTrue(app.staticTexts["Budget Review"].exists, "a result")
        open("Budget Review", in: app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)          // Anna, Budget Review's second speaker
        app.buttons["Go to Person"].tap()
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.appears(timeout: 10), "her page, pushed onto the Search tab")
        XCTAssertEqual(page.buttons.firstMatch.label, "Search", "Back goes to the results")

        tapTag("finance", inRow: "Licence Planning", app)
        XCTAssertTrue(app.buttons["Remove finance"].appears(timeout: 5), "the tag as a token")
        XCTAssertTrue(app.buttons["Remove Anna Schmidt"].exists, "with her")
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "no text")
        XCTAssertTrue(app.staticTexts["Licence Planning"].appears(timeout: 5)
                        && app.staticTexts["Budget Review"].exists, "her transcripts tagged finance")
        XCTAssertFalse(app.staticTexts["Project Kickoff"].exists)
        shot("Tag search from her page", app)

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(page.appears(timeout: 5), "Close comes back to her page")
        XCTAssertTrue(app.staticTexts["3 Transcripts"].appears(timeout: 5), "her page, as it was")
        shot("Back on her page in Search", app)
        page.buttons.firstMatch.tap()                                    // Back
        XCTAssertTrue(page.disappears(timeout: 5))
        XCTAssertEqual(field.value as? String, "budget", "the search her page was over")
        XCTAssertFalse(app.buttons["Remove Anna Schmidt"].exists, "without her token")
        XCTAssertTrue(app.staticTexts["Budget Review"].appears(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(field.disappears(timeout: 5), "Search closed")
        XCTAssertTrue(app.buttons["Transcripts"].firstMatch.isSelected, "back on the tab Search was opened from")
    }

    /// The same person twice in one stack (Anna, Lena, Anna: Go to Person from cards opened on the pages pushes, as
    /// Music's Go to Artist does): the top page's row opens the card and takes it back (the page under it has rows with
    /// their own zoom source ids), and Back goes through Lena to the first Anna.
    @MainActor
    func testSamePersonTwiceInOneStack() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)          // Anna
        app.buttons["Go to Person"].tap()
        let anna = app.navigationBars["Anna Schmidt"], lena = app.navigationBars["Lena Vogel"]
        XCTAssertTrue(anna.appears(timeout: 10), "Anna's page")

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)          // Lena, Budget Review's first speaker
        app.buttons["Go to Person"].tap()
        XCTAssertTrue(lena.appears(timeout: 10), "Lena's page on top of Anna's")

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)          // Anna
        app.buttons["Go to Person"].tap()
        XCTAssertTrue(anna.appears(timeout: 10), "Anna's page again")
        XCTAssertEqual(anna.buttons.firstMatch.label, "Lena Vogel", "on top of Lena's")

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        sleep(1)
        closeCard(app)
        XCTAssertTrue(anna.appears(timeout: 5), "back on the top page")
        XCTAssertTrue(app.staticTexts["Budget Review"].isHittable, "its row in place")
        anna.buttons.firstMatch.tap()
        XCTAssertTrue(lena.appears(timeout: 5), "Back: Lena")
        lena.buttons.firstMatch.tap()
        XCTAssertTrue(anna.appears(timeout: 5), "Back: the first Anna")
        XCTAssertEqual(anna.buttons.firstMatch.label, "Transcripts")
    }

    /// "Go to Person" in a name row's long-press menu: the card shrinks away and Anna's page is pushed onto the
    /// Transcripts tab (its Back goes to the list). From a card opened on her own page, it only closes the card. An
    /// unnamed speaker's menu has no "Go to Person" (`-seedFiller 1`: Archive 1's speakers are unnamed).
    @MainActor
    func testGoToPersonFromCard() throws {
        let app = launch(["-seedFiller", "1", "-interactionTrace"])
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)
        let go = app.buttons["Go to Person"]
        XCTAssertTrue(go.appears(timeout: 5), "Go to Person in Anna's menu")
        XCTAssertTrue(app.buttons["Rename Speaker…"].exists, "under the speaker's own items")
        shot("Name row menu", app)
        go.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card shrank away")
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.appears(timeout: 5), "her page pushed")
        XCTAssertTrue(app.buttons["Transcripts"].firstMatch.isSelected, "onto the Transcripts tab")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
                        .appears(timeout: 10), "with what she said")
        shot("Go to Person", app)
        XCTAssertEqual(page.buttons.firstMatch.label, "Transcripts", "Back goes to the Transcripts list")

        // From a card opened on her page: back to that page, nothing pushed on top.
        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)          // Anna, Budget Review's second speaker
        XCTAssertTrue(go.appears(timeout: 5))
        go.tap()
        XCTAssertTrue(app.buttons["Minimize"].disappears(timeout: 5), "the card closed")
        XCTAssertTrue(page.appears(timeout: 5), "her page")
        page.buttons.firstMatch.tap()                                    // Back
        XCTAssertTrue(page.disappears(timeout: 5), "one page deep")
        XCTAssertTrue(app.staticTexts["Archive 1"].appears(timeout: 5), "the Transcripts list")
        sleep(1)                     // the pop finishes: on a loaded Mac, a tap right after it once opened nothing

        open("Archive 1", in: app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename Speaker…"].appears(timeout: 5), "the menu")
        XCTAssertFalse(go.exists, "an unnamed speaker is nobody's")
    }

    /// A page kept in a tab outlives its person: Anna's page pushed in the Transcripts tab, then Anna deleted in
    /// Settings › People, says "Person Deleted" (it is looked up by id; reading the deleted person would trap).
    @MainActor
    func testDeletedPersonPage() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)
        app.buttons["Go to Person"].tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].appears(timeout: 5), "her page in Transcripts")

        app.buttons["Settings"].firstMatch.tap()
        app.buttons["People"].tap()
        let anna = app.staticTexts["Anna Schmidt"]
        XCTAssertTrue(anna.appears(timeout: 5))
        anna.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()                            // the swipe action
        XCTAssertTrue(app.staticTexts["Delete Anna Schmidt?"].appears(timeout: 5), "asks first")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(anna.disappears(timeout: 5), "gone from People")

        app.buttons["Transcripts"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Person Deleted"].appears(timeout: 5), "the page says so")
        shot("Person deleted", app)

        // The selected tab tapped again pops its stack to the list, as in every iOS app.
        app.buttons["Transcripts"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Person Deleted"].disappears(timeout: 5), "back to the list")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].appears(timeout: 5), "the Transcripts list")
    }

    /// Delete Person on her own page: the page goes back to People as it is (she is deleted once it has gone, so it
    /// never turns into "Person Deleted" on the way), and she is no longer listed.
    @MainActor
    func testDeletePersonOnPage() throws {
        let app = launch(["-showPerson", "Anna Schmidt"])
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.appears(timeout: 10), "her page")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
                        .appears(timeout: 10), "her page drawn")
        page.buttons["More"].tap()
        app.buttons["Delete Person"].tap()
        XCTAssertTrue(app.staticTexts["Delete Anna Schmidt?"].appears(timeout: 5), "asks first")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Person Deleted"].exists, "not on the way out")
        XCTAssertTrue(app.navigationBars["People"].appears(timeout: 5), "back on People")
        XCTAssertFalse(app.staticTexts["Person Deleted"].exists)
        XCTAssertTrue(app.staticTexts["Anna Schmidt"].disappears(timeout: 5), "she is gone")
        XCTAssertTrue(app.staticTexts["Lena Vogel"].exists, "the others stay")
    }

    /// The page, People's counts and the menu item in German. iOS 27 doesn't inflect German (FED-78: People read
    /// "3 Transkript"), so the counts come from the catalog's plural variations: one and other both checked.
    @MainActor
    func testGermanPersonPage() throws {
        let app = launch(["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-seedLicencePlanning", "-showPerson", "Anna Schmidt"])
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.appears(timeout: 10))
        let last = app.descendants(matching: .any)["LastConversation"]
        XCTAssertTrue(last.appears(timeout: 5) && last.label.contains("Letztes Gespräch"), last.label)
        XCTAssertTrue(app.staticTexts["3 Transkripte"].appears(timeout: 10))
        let profile = app.descendants(matching: .any)["VoiceProfile"]
        XCTAssertTrue(profile.label.contains("Stimmprofil") && (profile.value as? String) == "Gespeichert", "\(profile.label) \(profile.value ?? "")")
        XCTAssertTrue(app.buttons["DeleteVoiceProfile"].label.contains("Stimmprofil löschen"))
        shot("Person page in German", app)

        page.buttons.firstMatch.tap()                                    // Back to People
        XCTAssertTrue(app.navigationBars["Personen"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 Transkripte"].appears(timeout: 5), "Jonas Weber")
        XCTAssertTrue(app.staticTexts["3 Transkripte"].exists, "Anna Schmidt")
        XCTAssertTrue(app.staticTexts["1 Transkript"].exists, "Lena Vogel")
        shot("People in German", app)
        app.staticTexts["Anna Schmidt"].tap()
        XCTAssertTrue(page.appears(timeout: 5) && app.staticTexts["Budget Review"].appears(timeout: 5))
        app.staticTexts["Budget Review"].tap()
        XCTAssertTrue(app.buttons["SpeakerHeader.1"].appears(timeout: 10))
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Zur Person"].appears(timeout: 5), "Go to Person in German")
        shot("Zur Person", app)
    }
}
