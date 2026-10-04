import XCTest

/// The automatic summary under the date line: three lines with "More", and the whole summary is the button that opens
/// and closes it. "Budget Review" is seeded with a summary of five lines.
final class SummaryTests: ScribeUITestCase {
    static let summary = "Travel for the two customer workshops is over plan and licences are under, so part of the "
        + "licence budget moves to travel once finance agrees. The numbers go to finance by Friday, together with the "
        + "third-quarter forecast for the whole year."

    @MainActor
    func testSummaryMoreAndLess() throws {
        let app = launch()
        // The list row reads "Budget Review, Yesterday at 9:41, 0:30, …" for VoiceOver: the "·" separators are hidden.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Budget Review'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("·"), "no separator in the row's label: \(row.label)")
        open("Budget Review", in: app)
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "a summary longer than three lines is a button")
        XCTAssertEqual(summary.value as? String, Self.summary, "VoiceOver reads all of it, also while it is collapsed")
        let collapsed = settledHeight(of: summary)
        XCTAssertGreaterThan(summary.frame.width, 300, "the whole width is the target")
        shot("Summary collapsed", app)

        summary.tap()
        XCTAssertTrue(waitFor { summary.frame.height > collapsed + 20 }, "tapping it shows all lines")
        let expanded = settledHeight(of: summary)              // the expansion is animated
        XCTAssertGreaterThan(expanded, collapsed + 20)
        shot("Summary expanded", app)

        summary.tap()
        XCTAssertTrue(waitFor { abs(summary.frame.height - collapsed) <= 1 }, "tapping again shows three lines again")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        }
        return condition()
    }

    /// The element's height once it stopped changing (two readings 0.2 s apart agree).
    @MainActor
    private func settledHeight(of element: XCUIElement) -> CGFloat {
        var last = element.frame.height
        for _ in 0..<20 {
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
            let height = element.frame.height
            if abs(height - last) < 0.5 { return height }
            last = height
        }
        return last
    }
}
