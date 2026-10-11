import SwiftUI
import SwiftData
import UIKit

@main
struct RecorderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services: AppServices
    @State private var spotlightSynced = false

    init() {
        NameSpeakersTip.configure()
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
                    // Spotlight (SpotlightIndex): at launch, and on the way to the background, where the user can
                    // search; a background task keeps the app awake for it.
                    if phase == .background || (phase == .active && !spotlightSynced) {
                        syncSpotlight(after: spotlightSynced ? 0 : 5)   // at launch after the first busy seconds
                        spotlightSynced = true
                    }
                    guard phase == .active else { return }
                    #if DEBUG
                    if WarmupBench.isRequested {               // QA: the models' cold timings, nothing else loading
                        Task { await WarmupBench.run() }
                        return
                    }
                    #endif
                    // The speaker models (pyannote any network, live model and Nemotron on Wi-Fi), pending speakers and
                    // the prewarm; nothing before the Welcome page (AppServices.startModelDownloads).
                    services.startModelDownloads()
                }
        }
        .modelContainer(services.container)
    }

    private func syncSpotlight(after delay: TimeInterval) {
        let context = services.container.mainContext
        try? context.save()                            // a title typed just now is in what is indexed
        let task = UIApplication.shared.beginBackgroundTask(withName: "Spotlight")
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await SpotlightIndex.sync(context)

            UIApplication.shared.endBackgroundTask(task)
        }
    }
}

/// Only for Gemma's background download (GemmaDownload): iOS launches or wakes Feder when its transfers have finished
/// while the app was suspended or not running, and wants a call back once their events are handled.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == GemmaDownload.sessionIdentifier else { return completionHandler() }
        nonisolated(unsafe) let completion = completionHandler    // UIKit's handler; called on the main queue
        GemmaDownload.shared.handleBackgroundEvents { completion() }
    }
}
