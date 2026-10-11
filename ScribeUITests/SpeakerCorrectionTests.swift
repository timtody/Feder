import XCTest

/// Hand corrections of the speakers (SpeakerCorrection) from a name row's long-press menu. "Project Kickoff" has four
/// turns: Anna Schmidt, Jonas Weber, Anna Schmidt, Jonas Weber (SpeakerHeader.0-3).
final class SpeakerCorrectionTests: ScribeUITestCase {
    @MainActor
    private func names(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'SpeakerHeader.'")).allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }

    @MainActor
    private func menu(_ app: XCUIApplication, header: Int, _ item: String, _ choice: String) {
        app.buttons["SpeakerHeader.\(header)"].press(forDuration: 1.0)
        let submenu = app.buttons[item]
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), "\(item) in the name row's menu")
        submenu.tap()
        let button = app.buttons[choice].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(choice) in \(item)")
        button.tap()
    }

    /// Jonas's first turn goes to Anna: Anna's first three turns are one; then Anna merged into Jonas (asked first):
    /// one speaker left.
    @MainActor
    func testAssignAndMerge() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        XCTAssertEqual(names(app), ["Anna Schmidt", "Jonas Weber", "Anna Schmidt", "Jonas Weber"])
        menu(app, header: 1, "Assign This Part To", "Anna Schmidt")
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber"] }, "\(names(app))")
        shot("Assigned to Anna", app)

        menu(app, header: 0, "Merge Into", "Jonas Weber")
        let merge = app.buttons["Merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "a merge asks first")
        merge.tap()
        XCTAssertTrue(waitFor { self.names(app) == ["Jonas Weber"] }, "\(names(app))")
        shot("Merged", app)
    }

    /// A turn to a new speaker: splitting a speaker that is two people.
    @MainActor
    func testAssignToNewSpeaker() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        menu(app, header: 2, "Assign This Part To", "New Speaker")
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber", "Speaker 3", "Jonas Weber"] },
                      "\(names(app))")
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
