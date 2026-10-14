import SwiftUI

/// The app's own screen colours (FED-107): the user found pure black in Dark Mode hard on the eyes and chose, from
/// mock-ups, "Cool mist" (#F5F7FA) in Light and "Blue night" (#111827) in Dark as the background of every screen.
/// Grouped rows sit one step above it, as iOS's do on its grouped background: white in Light (as before), #1F2937 in
/// Dark (the next step of the same blue-grey scale; on #111827 it stands out about as much as iOS's #1C1C1E rows do on
/// black: contrast 1.21 against 1.23). Text keeps WCAG AA on both: the label 17.7 / 14.7 : 1, the secondary label
/// 6.1 / 5.4 : 1, the accent 6.5 / 5.4 : 1 (Dark; Light as on iOS's own white and #F2F2F7).
///
/// iOS has no switch for the system background colours, so each screen sets its own: `.scrollContentBackground(.hidden)`
/// lets the colour show through a List, Form or ScrollView (`appScreenBackground`), and the rows of a grouped list get
/// the surface colour (`appRows`, or `AppForm` for Settings' forms).
/// Liquid Glass (the tab bar, the accessory, the card's toolbar) samples what is behind it, so it takes the tint by
/// itself. Not here: the lock screen (its own blue) and the sheets, which keep iOS's glass at partial height.
extension View {
    /// A screen's background: a plain List, a ScrollView or any view that fills the screen.
    func appScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(.appBackground))     // a ShapeStyle background reaches under the safe areas
    }

    /// The rows of a grouped List: one step lighter than the screen. Put on the List's content (its sections or rows),
    /// not on the List: there it reached no row (measured: still iOS's #1C1C1E in Dark).
    func appRows() -> some View {
        listRowBackground(Color(.appSurface))
    }
}

/// A Form on the app's background, its rows one step lighter (see `appRows`): Settings and its pages.
struct AppForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content.appRows()                      // on several sections at once, like a Group: each gets it
        }
        .appScreenBackground()
    }
}
