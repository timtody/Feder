import SwiftUI

/// A person's page in a navigation stack, by id, never the `Person` itself: a page left in a stack outlives its person
/// (deleted in Settings › People, or removed when a rename in a card opened from the page left them without
/// transcripts, `PeopleDirectory.removeIfUnused`), and reading a deleted @Model traps. `PersonView` looks the person up
/// by this id and says "Person Deleted" when they are gone.
nonisolated struct PersonRoute: Hashable, Sendable {
    var id: UUID
}

/// The tabs' navigation stacks, owned by MainView (in memory only), so a person's page can be pushed onto the tab under
/// the card ("Go to Person", like Apple Music's Go to Artist) and a fresh search can clear the Search tab's stack. The
/// Transcripts and Search tabs push only person pages; Settings pushes its own pages (`SettingsRoute`) and person pages.
@MainActor @Observable
final class AppNavigation {
    var transcripts: [PersonRoute] = []
    var search: [PersonRoute] = []
    var settings = NavigationPath()

    /// Pushes `route` onto `tab`'s stack, unless it is on top there already.
    func push(_ route: PersonRoute, on tab: AppTab) {
        switch tab {
        case .transcripts: if transcripts.last != route { transcripts.append(route) }
        case .search: if search.last != route { search.append(route) }
        case .settings: settings.append(route)                   // an untyped path: its top can't be read
        case .ask: break                                         // no pages (MainView pushes on Transcripts instead)
        }
    }

    /// The name of `tab`'s stack in a person page's zoom source ids (`PersonView`'s rows): every tab stays alive, so
    /// the same transcript can be a row on a person's page in two stacks at once.
    static func stackName(_ tab: AppTab) -> String {
        switch tab {
        case .transcripts: "transcripts"
        case .search: "search"
        case .settings: "settings"
        case .ask: "ask"
        }
    }
}

/// Opens a person's page on the tab under the card, once the card has shrunk away (MainView's `openPerson`): the
/// name rows' "Go to Person".
struct OpenPersonAction {
    let open: (UUID) -> Void

    func callAsFunction(_ id: UUID) { open(id) }
}

extension EnvironmentValues {
    @Entry var openPerson: OpenPersonAction? = nil
}

extension View {
    /// Where a stack's root registers person pages (Settings, and the Transcripts and Search lists).
    func personDestination(stack: AppTab) -> some View {
        navigationDestination(for: PersonRoute.self) { route in
            PersonView(personID: route.id, stack: AppNavigation.stackName(stack))
        }
    }
}
