import XCTest

/// The card's Share menu (TranscriptExport): the formats and the two options; a format opens the share sheet with the
/// file. (The files themselves were checked from the simulator's container with `-exportAllFormats`: README › Export.)
final class ExportTests: ScribeUITestCase {
    @MainActor
    func testShareMenuFormats() throws {
        let app = launch()
        open("Budget Review", in: app)
        app.buttons["Share Transcript"].tap()
        for format in ["Text", "PDF", "Word Document", "Markdown", "Subtitles"] {
            XCTAssertTrue(app.buttons[format].appears(timeout: 5), "\(format) in the menu")
        }
        let names = app.switches["Speaker Names"].exists ? app.switches["Speaker Names"] : app.buttons["Speaker Names"]
        XCTAssertTrue(names.exists, "the speaker names option")
        XCTAssertTrue(app.buttons["Timestamps"].exists || app.switches["Timestamps"].exists, "the timestamps option")
        shot("Share menu", app)
        // An option keeps the menu open: toggled, the formats are still there.
        let timestamps = app.buttons["Timestamps"].exists ? app.buttons["Timestamps"] : app.switches["Timestamps"]
        timestamps.tap()
        XCTAssertTrue(app.buttons["PDF"].appears(timeout: 2), "the menu stays open after an option")
        sleep(1)
        XCTAssertTrue(app.buttons["PDF"].isHittable, "still open a moment later")
        timestamps.tap()                                    // back to off, as the next tests expect
        app.buttons["PDF"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.appears(timeout: 10) || app.navigationBars["UIActivityContentView"].exists,
                      "the share sheet")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Budget Review'")).firstMatch
                        .appears(timeout: 5), "with the file, named after the transcript")
        shot("Share PDF", app)
    }
}
