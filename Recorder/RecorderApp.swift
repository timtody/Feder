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
        RecordingLiveActivity.endLeftovers()
        if let opened = StoreRecovery.open() {
            let container = opened.container
            let services = AppServices(container: container)
            _services = State(initialValue: services)
            // App Lock: locked or not decided now and its window ready when the scene connects, so the first frame
            // never shows a transcript (AppLock).
            AppLockWindow.install(services.appLock)
            // Orphan sweep runs here, before any session can exist (never on scenePhase: a background recording may
            // be live). If the fetch fails, keep everything: an empty set would wipe every recording's audio. A WAV
            // without a row is a recording killed mid-way: it comes back as a transcript (FED-169) and the pending
            // pass after launch writes its words.
            var descriptor = FetchDescriptor<Recording>()
            descriptor.propertiesToFetch = [\.audioFileName]
            if opened.persistent, let rows = try? container.mainContext.fetch(descriptor) {
                let context = container.mainContext
                for file in RecordingRecovery.recoverOrphans(keeping: Set(rows.map(\.audioFileName))) {
                    let recording = Recording(name: String(localized: "Recovered Recording"), audioFileName: file.fileName,
                                              localeIdentifier: TranscriptionLanguage.current.identifier(.bcp47))
                    recording.createdAt = file.started
                    recording.duration = file.duration
                    context.insert(recording)
                }
                try? context.save()
            }
        } else {
            fatalError("Could not open any recordings store")
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
        #if LITERT
        if identifier == LabDownload.sessionIdentifier {               // Feder Lab's model files
            nonisolated(unsafe) let completion = completionHandler
            return LabDownload.shared.handleBackgroundEvents { completion() }
        }
        #endif
        guard identifier == GemmaDownload.sessionIdentifier else { return completionHandler() }
        nonisolated(unsafe) let completion = completionHandler    // UIKit's handler; called on the main queue
        GemmaDownload.shared.handleBackgroundEvents { completion() }
    }
}
