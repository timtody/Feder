import XCTest

/// A person's page (the Phone app's contact card: name as the large title, Last Conversation, Topics, their
/// transcripts with what they said), opened from Settings › People or with "Go to Person" from a card's name row, which
/// closes the card and pushes the page onto the tab under it (Apple Music's Go to Artist).
final class PersonPageTests: ScribeUITestCase {

    /// Settings › People › Anna Schmidt: her name as the title, when you last spoke, her two transcripts each with her
    /// longest turn quoted; a row opens the card at that turn ("1 of 2" through her turns, the turn marked), and
    /// closing it comes back to her page. No Topics section: her two transcripts share no topic.
    @MainActor
    func testPersonPageShowsWhatTheySaid() throws {
        let app = launch()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["People"].tap()
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5), "People pushed inside Settings")
        app.staticTexts["Anna Schmidt"].tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "her page, her name as the title")

        let last = app.descendants(matching: .any)["LastConversation"]
        XCTAssertTrue(last.waitForExistence(timeout: 5), "the Last Conversation row")
        XCTAssertTrue(last.label.contains("Last Conversation") && last.label.contains("Today at"),
                      "Project Kickoff is today: \(last.label)")
        XCTAssertTrue(app.staticTexts["2 Transcripts"].exists, "the transcripts' header")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists && app.staticTexts["Budget Review"].exists,
                      "her transcripts are listed")
        // Her longest turn in each: Budget Review's first one, Project Kickoff's second.
        let budgetQuote = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
        XCTAssertTrue(budgetQuote.waitForExistence(timeout: 10), "what she said in Budget Review")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Agreed. If we cut playback'"))
                        .firstMatch.exists, "what she said in Project Kickoff")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'PersonTopic.'")).firstMatch.exists,
                       "no topics: her transcripts share none")
        shot("Person page", app)
        // The separator between her transcripts starts at their text, inside the card (FED-74).
        assertSeparatorStartsAtText(under: "Project Kickoff", app)

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        XCTAssertTrue(app.staticTexts["Match 1 of 2"].waitForExistence(timeout: 5), "n of m through her turns")
        XCTAssertEqual(app.staticTexts["Paragraph.1"].value as? String, "Current match", "the quoted turn is marked")
        shot("Card at her turn", app)
        app.buttons["Next Match"].tap()
        XCTAssertTrue(app.staticTexts["Match 2 of 2"].waitForExistence(timeout: 5), "her second turn")
        closeCard(app)
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "back on her page")
    }

    /// `-seedPersonTopics` (a third transcript of Anna's, "Licence Planning", and Gemma's topics): her page lists the
    /// tag "finance" first, then the words they share. A word opens the Search tab with her as a token and the word as
    /// the text, and the search's close button comes back to her page; the tag searches her and the tag. A word only in
    /// Gemma's topics ("procurement": nobody says it, no summary has it) finds both transcripts too, since the search
    /// reads the topics. Opened again, her page has its topics at once (the last ones shown, then brought up to date).
    @MainActor
    func testPersonTopics() throws {
        let app = launch(["-seedPersonTopics", "-showPerson", "Anna Schmidt"])
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 10), "her page")
        let finance = app.buttons["PersonTopic.finance"]
        XCTAssertTrue(finance.waitForExistence(timeout: 10), "the tag on two of her transcripts")
        let travel = app.buttons["PersonTopic.travel"]
        XCTAssertTrue(travel.exists && app.buttons["PersonTopic.licences"].exists && app.buttons["PersonTopic.forecast"].exists
                        && app.buttons["PersonTopic.procurement"].exists, "the words in two of her transcripts' topics")
        XCTAssertFalse(app.buttons["PersonTopic.planning"].exists, "a tag on one transcript is no topic")
        XCTAssertLessThanOrEqual(finance.frame.minY, travel.frame.minY, "tags first")
        if finance.frame.minY == travel.frame.minY { XCTAssertLessThan(finance.frame.minX, travel.frame.minX, "tags first") }
        XCTAssertTrue(app.staticTexts["Topics"].exists, "the section's header")
        XCTAssertTrue(app.staticTexts["3 Transcripts"].exists)
        shot("Person topics", app)

        // The large title collapses into the bar on scroll, as in Contacts.
        let bar = app.navigationBars["Anna Schmidt"]
        let large = bar.frame.height
        app.swipeUp()
        let end = Date.now.addingTimeInterval(3)
        while Date.now < end, bar.frame.height > large - 20 { RunLoop.current.run(until: .now + 0.2) }
        note("Navigation bar", "large \(large), scrolled \(bar.frame.height)")
        shot("Person page scrolled", app)
        XCTAssertLessThan(bar.frame.height, large - 20, "the title collapsed into the bar")
        app.swipeDown()
        XCTAssertTrue(travel.waitForExistence(timeout: 5) && travel.isHittable, "back at the top")

        travel.tap()
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Search tab")
        XCTAssertEqual(field.value as? String, "travel", "the word as the text")
        XCTAssertTrue(app.buttons["Remove Anna Schmidt"].exists, "her as the token")
        XCTAssertEqual(app.buttons.matching(identifier: "SearchToken").count, 1, "only her")
        XCTAssertTrue(app.staticTexts["Licence Planning"].waitForExistence(timeout: 5)
                        && app.staticTexts["Budget Review"].exists, "her transcripts about travel")
        XCTAssertFalse(app.staticTexts["Project Kickoff"].exists, "not the one without it")
        shot("Topic search", app)

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "back on her page")
        app.buttons["PersonTopic.finance"].tap()
        XCTAssertTrue(app.buttons["Remove finance"].waitForExistence(timeout: 5), "the tag as a token")
        XCTAssertTrue(app.buttons["Remove Anna Schmidt"].exists, "with her")
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "no text")
        XCTAssertTrue(app.staticTexts["Licence Planning"].waitForExistence(timeout: 5)
                        && app.staticTexts["Budget Review"].exists, "her transcripts tagged finance")
        XCTAssertFalse(app.staticTexts["Project Kickoff"].exists)

        // A plural searches its shortest form ("Licence" in a title), which finds the plural too.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "back on her page")
        app.buttons["PersonTopic.licences"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "licence", "the singular, which the search finds inside the plural")
        XCTAssertTrue(app.staticTexts["Licence Planning"].waitForExistence(timeout: 5)
                        && app.staticTexts["Budget Review"].exists, "both of her transcripts about licences")

        // A word only in Gemma's topics: the search reads them, so the chip's two transcripts are its results.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "back on her page")
        app.buttons["PersonTopic.procurement"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "procurement")
        XCTAssertTrue(app.staticTexts["Licence Planning"].waitForExistence(timeout: 5)
                        && app.staticTexts["Budget Review"].exists, "found in their topics")
        XCTAssertTrue(app.staticTexts["2 Transcripts"].exists, "as many as the chip says")
        shot("Topic only in Gemma's topics", app)

        // Opened again from People: the topics are there with the page, not inserted after the push.
        app.buttons["Close"].firstMatch.tap()
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "back on her page")
        page.buttons.firstMatch.tap()                                    // Back to People
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5))
        app.staticTexts["Anna Schmidt"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["PersonTopic.travel"].exists, "her topics, with the page")
    }

    /// A topic on her page in the Search tab (Go to Person from a result's card): the fresh search replaces the one her
    /// page was over, and Close comes back to her page, whose Back leads to that earlier search; its Close then leaves
    /// Search for the tab it was opened from.
    @MainActor
    func testTopicOnPageInSearchTab() throws {
        let app = launch(["-seedPersonTopics"])
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the Search tab")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the field has the focus")
        dismissKeyboardTip(app)
        app.typeText("budget")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForNonExistence(timeout: 10), "the results")
        XCTAssertTrue(app.staticTexts["Budget Review"].exists, "a result")
        open("Budget Review", in: app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)          // Anna, Budget Review's second speaker
        app.buttons["Go to Person"].tap()
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "her page, pushed onto the Search tab")
        XCTAssertEqual(page.buttons.firstMatch.label, "Search", "Back goes to the results")
        let travel = app.buttons["PersonTopic.travel"]
        XCTAssertTrue(travel.waitForExistence(timeout: 10))

        travel.tap()
        XCTAssertTrue(app.buttons["Remove Anna Schmidt"].waitForExistence(timeout: 5), "her as the token")
        XCTAssertEqual(field.value as? String, "travel")
        XCTAssertTrue(app.staticTexts["Licence Planning"].waitForExistence(timeout: 5), "her transcripts about travel")
        XCTAssertFalse(app.staticTexts["Project Kickoff"].exists)

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "Close comes back to her page")
        XCTAssertTrue(travel.waitForExistence(timeout: 5), "her page, as it was")
        shot("Back on her page in Search", app)
        page.buttons.firstMatch.tap()                                    // Back
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "budget", "the search her page was over")
        XCTAssertFalse(app.buttons["Remove Anna Schmidt"].exists, "without her token")
        XCTAssertTrue(app.staticTexts["Budget Review"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Search closed")
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
        XCTAssertTrue(anna.waitForExistence(timeout: 10), "Anna's page")

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)          // Lena, Budget Review's first speaker
        app.buttons["Go to Person"].tap()
        XCTAssertTrue(lena.waitForExistence(timeout: 10), "Lena's page on top of Anna's")

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)          // Anna
        app.buttons["Go to Person"].tap()
        XCTAssertTrue(anna.waitForExistence(timeout: 10), "Anna's page again")
        XCTAssertEqual(anna.buttons.firstMatch.label, "Lena Vogel", "on top of Lena's")

        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        sleep(1)
        closeCard(app)
        XCTAssertTrue(anna.waitForExistence(timeout: 5), "back on the top page")
        XCTAssertTrue(app.staticTexts["Budget Review"].isHittable, "its row in place")
        anna.buttons.firstMatch.tap()
        XCTAssertTrue(lena.waitForExistence(timeout: 5), "Back: Lena")
        lena.buttons.firstMatch.tap()
        XCTAssertTrue(anna.waitForExistence(timeout: 5), "Back: the first Anna")
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
        XCTAssertTrue(go.waitForExistence(timeout: 5), "Go to Person in Anna's menu")
        XCTAssertTrue(app.buttons["Rename Speaker…"].exists, "under the speaker's own items")
        shot("Name row menu", app)
        go.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "the card shrank away")
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "her page pushed")
        XCTAssertTrue(app.buttons["Transcripts"].firstMatch.isSelected, "onto the Transcripts tab")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
                        .waitForExistence(timeout: 10), "with what she said")
        shot("Go to Person", app)
        XCTAssertEqual(page.buttons.firstMatch.label, "Transcripts", "Back goes to the Transcripts list")

        // From a card opened on her page: back to that page, nothing pushed on top.
        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)          // Anna, Budget Review's second speaker
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        go.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "the card closed")
        XCTAssertTrue(page.waitForExistence(timeout: 5), "her page")
        page.buttons.firstMatch.tap()                                    // Back
        XCTAssertTrue(page.waitForNonExistence(timeout: 5), "one page deep")
        XCTAssertTrue(app.staticTexts["Archive 1"].waitForExistence(timeout: 5), "the Transcripts list")
        sleep(1)                     // the pop finishes: on a loaded Mac, a tap right after it once opened nothing

        open("Archive 1", in: app)
        app.buttons["SpeakerHeader.0"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename Speaker…"].waitForExistence(timeout: 5), "the menu")
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
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "her page in Transcripts")

        app.buttons["Settings"].firstMatch.tap()
        app.buttons["People"].tap()
        let anna = app.staticTexts["Anna Schmidt"]
        XCTAssertTrue(anna.waitForExistence(timeout: 5))
        anna.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()                            // the swipe action
        XCTAssertTrue(app.staticTexts["Delete Anna Schmidt?"].waitForExistence(timeout: 5), "asks first")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(anna.waitForNonExistence(timeout: 5), "gone from People")

        app.buttons["Transcripts"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Person Deleted"].waitForExistence(timeout: 5), "the page says so")
        shot("Person deleted", app)

        // The selected tab tapped again pops its stack to the list, as in every iOS app.
        app.buttons["Transcripts"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Person Deleted"].waitForNonExistence(timeout: 5), "back to the list")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 5), "the Transcripts list")
    }

    /// Delete Person on her own page: the page goes back to People as it is (she is deleted once it has gone, so it
    /// never turns into "Person Deleted" on the way), and she is no longer listed.
    @MainActor
    func testDeletePersonOnPage() throws {
        let app = launch(["-showPerson", "Anna Schmidt"])
        let page = app.navigationBars["Anna Schmidt"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "her page")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The travel overrun'")).firstMatch
                        .waitForExistence(timeout: 10), "her page drawn")
        page.buttons["More"].tap()
        app.buttons["Delete Person"].tap()
        XCTAssertTrue(app.staticTexts["Delete Anna Schmidt?"].waitForExistence(timeout: 5), "asks first")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Person Deleted"].exists, "not on the way out")
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5), "back on People")
        XCTAssertFalse(app.staticTexts["Person Deleted"].exists)
        XCTAssertTrue(app.staticTexts["Anna Schmidt"].waitForNonExistence(timeout: 5), "she is gone")
        XCTAssertTrue(app.staticTexts["Lena Vogel"].exists, "the others stay")
    }

    /// The page and the menu item in German.
    @MainActor
    func testGermanPersonPage() throws {
        let app = launch(["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-seedPersonTopics", "-showPerson", "Anna Schmidt"])
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 10))
        let last = app.descendants(matching: .any)["LastConversation"]
        XCTAssertTrue(last.waitForExistence(timeout: 5) && last.label.contains("Letztes Gespräch"), last.label)
        XCTAssertTrue(app.staticTexts["Themen"].waitForExistence(timeout: 10), "the Topics header")
        XCTAssertTrue(app.staticTexts["3 Transkripte"].exists)
        shot("Person page in German", app)
        app.staticTexts["Budget Review"].tap()
        XCTAssertTrue(app.buttons["SpeakerHeader.1"].waitForExistence(timeout: 10))
        app.buttons["SpeakerHeader.1"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Zur Person"].waitForExistence(timeout: 5), "Go to Person in German")
        shot("Zur Person", app)
    }
}
