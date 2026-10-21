import Foundation
import SwiftData
import UIKit

/// Opens the transcripts store, and when it can't be opened (damage, a failed migration, a full disk) keeps Feder
/// launchable instead of ending in `fatalError` at every start (FED-171): the store's files move, never deleted, to
/// Application Support/Recovery/<timestamp>, and a fresh store opens. The audio stays in Documents/Recordings, so the
/// launch sweep turns every file into a pending "Recovered Recording" (RecordingRecovery): the words come back, names
/// and edits don't.
enum StoreRecovery {
    struct Opened {
        var container: ModelContainer
        /// False when the container lives in memory only (nothing can be saved): the launch sweep must not run on it.
        var persistent: Bool
    }

    static func open() -> Opened? {
        if let container = try? ModelContainer(for: Recording.self, Person.self) {
            return Opened(container: container, persistent: true)
        }
        // The iPhone is locked after a reboot: the store's files can't be opened yet (data protection), which is no
        // damage. Nothing is moved; an empty in-memory store keeps this (background) launch alive and the next one finds
        // the store. (`isProtectedDataAvailable` is false in App.init whatever the state, so the file is tried.)
        guard storeIsReadable() else { return inMemory() }
        guard moveStoreAside() else { return inMemory() }
        if let container = try? ModelContainer(for: Recording.self, Person.self) {
            return Opened(container: container, persistent: true)
        }
        return inMemory()
    }

    private static func storeIsReadable() -> Bool {
        let store = URL.applicationSupportDirectory.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: store.path) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: store) else { return false }
        try? handle.close()
        return true
    }

    private static func inMemory() -> Opened? {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: Recording.self, Person.self, configurations: configuration) else {
            return nil
        }
        return Opened(container: container, persistent: false)
    }

    /// default.store with its -wal and -shm into Recovery/<timestamp>; true when the store is out of the way.
    private static func moveStoreAside() -> Bool {
        let fileManager = FileManager.default
        let support = URL.applicationSupportDirectory
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let target = support.appending(path: "Recovery/\(stamp)", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var moved = false
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            let source = support.appending(path: name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            do {
                try fileManager.moveItem(at: source, to: target.appending(path: name))
                moved = true
            } catch {
                return false
            }
        }
        return moved
    }
}
