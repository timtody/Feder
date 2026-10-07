import SwiftUI
import SwiftData

@main
struct RecorderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var services: AppServices

    init() {
        do {
            let container = try ModelContainer(for: Recording.self, Person.self)
            _services = State(initialValue: AppServices(container: container))
            // Orphan sweep runs here, before any session can exist (never on scenePhase: a background recording may
            // be live). If the fetch fails, keep everything: an empty set would wipe every recording's audio.
            var descriptor = FetchDescriptor<Recording>()
            descriptor.propertiesToFetch = [\.audioFileName]
            if let rows = try? container.mainContext.fetch(descriptor) {
                AudioFileStore.removeOrphans(keeping: Set(rows.map(\.audioFileName)))
            }
        } catch {
            fatalError("Could not open the recordings store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(services)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await services.identifier.prepareAndRetryPending()
                        await services.identifier.refreshVoices()       // once per transcript: voices from final labels
                    }
                    if !services.usesFakes {               // the simulator uses fake engines: no model downloads
                        Task { await services.nemotron.download(force: false) }   // Wi-Fi only; no-op once downloaded
                        // (Parakeet is not downloaded here: it is optional, only on the user's tap in Settings.)
                    }
                    Task { await services.prepareLiveDiarizer() }   // independent: neither waits for the other
                }
        }
        .modelContainer(services.container)
    }
}
