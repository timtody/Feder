import XCTest

/// The card's player (TranscriptPlayer, PlayerBar) and tapping a word to hear it (WordParagraph). A transcript recorded
/// on the simulator has its audio file (the seeded samples have none, so they show no player).
final class PlaybackTests: ScribeUITestCase {
    @MainActor
    private func seconds(_ label: String) -> Int {
        let parts = label.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }

    @MainActor
    func testPlayPauseAndTapAWord() throws {
        XCUIApplication().terminate()
        let app = launch(["-autoRecord", "-autoStopAfter", "12"])
        XCTAssertTrue(app.buttons["Delete Transcript"].waitForExistence(timeout: 30), "saved: the transcript")
        let play = app.buttons["PlayPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "the player bar")
        let time = app.staticTexts["PlaybackTime"]
        XCTAssertEqual(time.label, "0:00")
        play.tap()
        XCTAssertTrue(time.wait(for: \.label, toEqual: "0:02", timeout: 5), "it plays: \(time.label)")
        XCTAssertEqual(play.label, "Pause")
        shot("Playing", app)
        play.tap()
        let paused = time.label
        sleep(2)
        XCTAssertEqual(time.label, paused, "paused")

        // A word in the last paragraph: playback jumps there (its paragraph starts several seconds in).
        let paragraphs = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'Paragraph.'"))
        let last = paragraphs.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY }!
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertTrue(time.wait(for: \.label, toEqual: time.label, timeout: 0.1))   // settle
        sleep(1)
        XCTAssertGreaterThanOrEqual(seconds(time.label), 4, "jumped to the tapped word: \(time.label)")
        XCTAssertEqual(play.label, "Pause", "and plays")
        shot("Tapped word", app)
        play.tap()

        // Deleted again: each recorded test transcript is newer than the samples and pushes Budget Review down the
        // list the other tests open it from.
        app.buttons["Delete Transcript"].tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
    }
}
