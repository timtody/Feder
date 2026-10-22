import Foundation
import SwiftData
import UIKit

/// Opens the transcripts store, and when it can't be opened (damage, a failed migration, a full disk) keeps Feder
/// launchable instead of ending in `fatalError` at every start (FED-171): the store's files move, never deleted, to
/// Application Support/Recovery/<timestamp>, and a fresh store opens. The audio stays in Documents/Recordings, so the
/// launch sweep turns every file into a pending "Recovered Recording" (RecordingRecovery): the words come back, names
/// and edits don't. The user is told (StoreRecoveryNotice): Share Recovery Files, Try the Old List Again (asked for
/// here, done at the next launch, since a running app can't swap its store) or keep the new one.
enum StoreRecovery {
    /// UserDefaults: the folder in Recovery/ of the store set aside last, while the user hasn't dismissed the notice.
    private static let noticeKey = "storeRecoveryFolder"
    /// UserDefaults: the user asked to try that folder's store again at the next launch.
    private static let restoreKey = "storeRecoveryRestore"

    struct Notice: Identifiable {
        var folder: URL
        var files: [URL]
        var id: URL { folder }
    }

    struct Opened {
        var container: ModelContainer
        /// False when the container lives in memory only (nothing can be saved): the launch sweep must not run on it.
        var persistent: Bool
    }

    static func open() -> Opened? {
        applyRestoreIfRequested()
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

    private static var support: URL { URL.applicationSupportDirectory }
    private static var recoveryDirectory: URL { support.appending(path: "Recovery", directoryHint: .isDirectory) }
    private static let storeFiles = ["default.store", "default.store-wal", "default.store-shm"]

    private static func stamp() -> String {
        ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
    }

    /// default.store with its -wal and -shm into Recovery/<timestamp>, remembered for the notice; true when the store
    /// is out of the way.
    private static func moveStoreAside() -> Bool {
        let name = stamp()
        guard moveStoreFiles(from: support, to: recoveryDirectory.appending(path: name, directoryHint: .isDirectory)) else {
            return false
        }
        UserDefaults.standard.set(name, forKey: noticeKey)
        return true
    }

    /// The store's files from one folder into another (created); true when at least one moved and none failed.
    private static func moveStoreFiles(from source: URL, to target: URL) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var moved = false
        for name in storeFiles {
            let file = source.appending(path: name)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                try fileManager.moveItem(at: file, to: target.appending(path: name))
                moved = true
            } catch {
                return false
            }
        }
        return moved
    }

    // MARK: The notice

    /// What was set aside and not yet answered, if the folder is still there.
    static var notice: Notice? {
        guard let name = UserDefaults.standard.string(forKey: noticeKey) else { return nil }
        let folder = recoveryDirectory.appending(path: name, directoryHint: .isDirectory)
        let files = storeFiles.map { folder.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            UserDefaults.standard.removeObject(forKey: noticeKey)
            return nil
        }
        return Notice(folder: folder, files: files)
    }

    /// Keep the new list: the files stay in Recovery/ (never deleted), only the notice goes. Not after Try Again: the
    /// folder is still needed at the next launch.
    static func dismissNotice() {
        guard !UserDefaults.standard.bool(forKey: restoreKey) else { return }
        UserDefaults.standard.removeObject(forKey: noticeKey)
    }

    /// The next launch puts the set-aside store back and sets the current one aside in its place.
    static func restoreAtNextLaunch() { UserDefaults.standard.set(true, forKey: restoreKey) }

    /// A failed open of the old store moves it aside again (a new notice), so asking again is never a crash loop.
    private static func applyRestoreIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: restoreKey) else { return }
        defaults.removeObject(forKey: restoreKey)
        guard let name = defaults.string(forKey: noticeKey) else { return }
        let old = recoveryDirectory.appending(path: name, directoryHint: .isDirectory)
        let replaced = recoveryDirectory.appending(path: "\(stamp())-replaced", directoryHint: .isDirectory)
        // The list in use (the fresh one with the recovered recordings) goes aside first: nothing is overwritten.
        guard FileManager.default.fileExists(atPath: old.appending(path: "default.store").path) else { return }
        _ = moveStoreFiles(from: support, to: replaced)
        if moveStoreFiles(from: old, to: support) { defaults.removeObject(forKey: noticeKey) }
    }
}
