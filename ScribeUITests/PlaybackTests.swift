import XCTest

/// Listen: the card's player (TranscriptPlayer, PlayerBar) and tapping a word to hear it (WordParagraph), from the
/// toolbar's headphones until the bar's close button. A transcript recorded on the simulator has its audio file (the
/// seeded samples have none: Listen is greyed out there).
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
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.wait(for: \.isEnabled, toEqual: true, timeout: 10), "Listen, with the audio there")
        XCTAssertFalse(play.exists, "no player until Listen")
        listen.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Listen shows the player bar")
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

        // The slider to the end while playing: it stops there (it used to start again from 0:00).
        let slider = app.sliders["Playback Position"]
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(play.wait(for: \.label, toEqual: "Play", timeout: 3), "stopped at the end")
        sleep(1)
        XCTAssertGreaterThanOrEqual(seconds(time.label), 11, "at the end, not from the start: \(time.label)")
        // Play at the end: from the beginning again.
        play.tap()
        XCTAssertTrue(time.wait(for: \.label, toEqual: "0:01", timeout: 4), "again from the start: \(time.label)")

        // Find while it plays (FED-79): the find bar takes the player's place and playback goes on; closing Find brings
        // the player back, still playing.
        app.buttons["FindButton"].tap()
        let field = app.textFields["FindField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar")
        XCTAssertTrue(play.waitForNonExistence(timeout: 3), "in the player's place")
        shot("Find while listening", app)
        sleep(2)
        app.buttons["Close Find"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5), "the player is back")
        XCTAssertEqual(play.label, "Pause", "still playing")
        XCTAssertGreaterThanOrEqual(seconds(time.label), 3, "it played on under the find bar: \(time.label)")
        play.tap()

        // The bar's close button ends Listen: the bar goes, a tap on a word plays nothing.
        app.buttons["ClosePlayer"].tap()
        XCTAssertTrue(play.waitForNonExistence(timeout: 3), "the bar is gone")
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertFalse(play.waitForExistence(timeout: 1), "and stays gone")

        // Deleted again: each recorded test transcript is newer than the samples and pushes Budget Review down the
        // list the other tests open it from.
        app.buttons["Delete Transcript"].tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5))
    }
}
