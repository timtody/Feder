import SwiftUI
import UIKit

extension UIColor {
    /// The accent as Light Mode draws it (AccentColor's any-appearance value), read from the asset so everything here
    /// follows when the accent changes. Resolved once, without a dynamic provider: a provider closure would be
    /// main-actor isolated here and UIKit may resolve it off the main thread.
    nonisolated static let accentLight: UIColor = UIColor(named: "AccentColor")?
        .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        ?? UIColor(red: 47 / 255, green: 107 / 255, blue: 219 / 255, alpha: 1)
}

extension Color {
    /// The fill behind white text (search tokens, a matched chip, the bookmark count, prominent buttons): the light
    /// accent in both appearances, as Signal's blue. Dark Mode's accent is lighter so that it reads as text on black
    /// (#6F9CF0, 7.7:1), which leaves white on it at 2.8:1; on the light one white reaches 4.9:1 (FED-107).
    nonisolated static let accentFill = Color(uiColor: .accentLight)
}
