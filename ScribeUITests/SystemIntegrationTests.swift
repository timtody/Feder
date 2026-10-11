import XCTest

/// Feder outside its own screens: the iPhone's search (Spotlight).
final class SystemIntegrationTests: ScribeUITestCase {
    /// The transcripts are in Core Spotlight's index (SpotlightIndex), found by a word of their text, and a result opens
    /// its card. The simulator's Spotlight screen shows no app content (iOS 27), so `-openSpotlightResult` asks the index
    /// as Spotlight does and opens the first result through the same path as a tapped result (MainView.openFromOutside).
    @MainActor
    func testSpotlightFindsTranscript() throws {
        let app = launch(["-openSpotlightResult", "workshops"])     // a word only in Budget Review's text
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].waitForExistence(timeout: 20), "the result's card opens")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        closeCard(app)
        XCTAssertTrue(app.staticTexts["Budget Review"].exists, "back in the Transcripts list")
    }
}
