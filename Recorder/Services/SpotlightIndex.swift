import CoreSpotlight
import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// The transcripts in the iPhone's own search (Spotlight): title, summary, tags, speaker names, the words and the
/// action items, so a search on the home screen for "budget" finds the transcript and opens its card (MainView's
/// `onContinueUserActivity`). The index is Core Spotlight's on the device; it never leaves the iPhone (not eligible for
/// public indexing), and with `.complete` protection it is readable only while the iPhone is unlocked. Opt-in
/// (`enabledKey`, off until the user turns it on in the onboarding or Settings, October 2026): the transcripts then
/// also sit in a system index outside the app's store, and what the user types into the iPhone's search can go to
/// Apple for suggestions (iOS's, not Feder's), so it is the user's choice, like voice profiles. Off, the index is
/// deleted.
///
/// Kept in step by `sync`: at launch and whenever the app goes to the background (before the user can use Spotlight).
/// It compares a key per transcript (`indexKey`: title, tags, summary, speakers, edits, the action items' tasks; not
/// the words, which are the expensive SwiftData read) with what was indexed (`keysKey`), reads the changed ones'
/// paragraphs a few per turn of the main actor (as the in-app search does), and hands them to Core Spotlight off the
/// main actor; ids that are gone leave the index. A deleted transcript leaves it at once (`remove`), not only at the
/// next sync.
enum SpotlightIndex {
    nonisolated static let domain = "transcripts"
    /// UserDefaults: `[id: indexKey]` of what is in the index.
    nonisolated static let keysKey = "spotlightKeys"
    /// UserDefaults: "Show in iPhone Search" (onboarding, Settings); absent means off.
    nonisolated static let enabledKey = "spotlightIndexing"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// Transcripts whose paragraphs are read per turn of the main actor.
    private static let batch = 8

    /// What one transcript contributes.
    nonisolated struct Entry: Sendable {
        var id: String
        var title: String
        var summary: String?
        var text: String
        var keywords: [String]
        var created: Date
        var duration: TimeInterval
    }

    nonisolated private static var index: CSSearchableIndex {
        CSSearchableIndex(name: "Feder", protectionClass: .complete)
    }

    /// Brings the index up to date with the store.
    static func sync(_ context: ModelContext) async {
        guard isEnabled else {
            // Off: everything Feder put into the index goes (also what an earlier build indexed before it was opt-in).
            guard UserDefaults.standard.dictionary(forKey: keysKey) != nil else { return }
            if await deleteAll() { UserDefaults.standard.removeObject(forKey: keysKey) }
            return
        }
        guard let recordings = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let known = UserDefaults.standard.dictionary(forKey: keysKey) as? [String: String] ?? [:]
        let keys = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id.uuidString, indexKey($0)) })
        let changed = recordings.filter { known[$0.id.uuidString] != keys[$0.id.uuidString] }
        let gone = Array(Set(known.keys).subtracting(keys.keys))
        guard !changed.isEmpty || !gone.isEmpty else { return }
        var entries: [Entry] = []
        for start in stride(from: 0, to: changed.count, by: batch) {
            for recording in changed[start..<min(start + batch, changed.count)]
            where !recording.isDeleted && recording.modelContext != nil {
                entries.append(entry(recording))
            }
            await Task.yield()
        }
        guard await write(entries, removing: gone) else { return }
        #if DEBUG
        print("[Scribe] spotlight: indexed \(entries.count), removed \(gone.count)")
        #endif
        UserDefaults.standard.set(keys, forKey: keysKey)
    }

    @concurrent
    nonisolated private static func deleteAll() async -> Bool {
        (try? await index.deleteAllSearchableItems()) != nil
    }

    @concurrent
    nonisolated private static func write(_ entries: [Entry], removing gone: [String]) async -> Bool {
        do {
            if !gone.isEmpty { try await index.deleteSearchableItems(withIdentifiers: gone) }
            if !entries.isEmpty { try await index.indexSearchableItems(entries.map(item)) }
            return true
        } catch {
            #if DEBUG
            print("[Scribe] spotlight: \(error)")
            #endif
            return false
        }
    }

    /// Changes whenever anything indexed changes; stable across launches (SHA-256, not Hasher, which is seeded per
    /// process and would re-index everything at every launch).
    private static func indexKey(_ recording: Recording) -> String {
        let speakers = recording.speakerNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let parts: [String] = [recording.name, recording.tags.joined(separator: ","), recording.summary ?? "",
                               recording.speakerStatusRaw, String(recording.wordsRefined),
                               String(recording.vocabularyPending), String(recording.speakerCountOverride ?? 0),
                               speakers.joined(separator: ","), String(recording.createdAt.timeIntervalSince1970),
                               String(recording.duration), String(recording.editCount), tasks(of: recording)]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// QA (`-openSpotlightResult <text>`, MainView): the ids Core Spotlight finds for `text` among Feder's items,
    /// asked the way Spotlight asks. The simulator's Spotlight screen shows no app content (iOS 27, checked with this
    /// index and the default one), so the UI test goes through the index and the result's opening path from here.
    nonisolated static func debugQuery(_ text: String) async -> [String] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        let query = CSSearchQuery(queryString: "textContent == \"*\(text)*\"cd || title == \"*\(text)*\"cd",
                                  queryContext: context)
        var titles: [String] = []
        do {
            for try await result in query.results { titles.append(result.item.uniqueIdentifier) }
        } catch {
            titles.append("error: \(error)")
        }
        return titles
    }
    #endif

    /// A deleted transcript: out of the index now.
    static func remove(_ id: UUID) {
        index.deleteSearchableItems(withIdentifiers: [id.uuidString]) { _ in }
        var known = UserDefaults.standard.dictionary(forKey: keysKey) as? [String: String] ?? [:]
        known[id.uuidString] = nil
        UserDefaults.standard.set(known, forKey: keysKey)
    }

    /// The transcript id of a Spotlight result the user tapped.
    nonisolated static func recordingID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
    }

    private static func entry(_ recording: Recording) -> Entry {
        let named = recording.speakerStatus == .done
        let text = recording.segments.map { segment in
            if named, let speaker = segment.speakerIndex { return "\(recording.speakerName(speaker)): \(segment.text)" }
            return segment.text
        }.joined(separator: "\n")
        let speakers = named ? Set(recording.segments.compactMap(\.speakerIndex)).compactMap { recording.speakerNames[$0] } : []
        // The action items as words of the transcript's own entry (items of their own would look like reminders).
        let tasks = tasks(of: recording)
        return Entry(id: recording.id.uuidString, title: recording.name, summary: recording.summary,
                     text: tasks.isEmpty ? text : text + "\n" + tasks,
                     keywords: recording.tags + speakers.sorted(), created: recording.createdAt,
                     duration: recording.duration)
    }

    /// The tasks the user didn't remove, one per line (a small decode per transcript; added flags don't re-index).
    private static func tasks(of recording: Recording) -> String {
        recording.actionItems.filter { !$0.isRemoved }.map(\.task).joined(separator: "\n")
    }

    nonisolated private static func item(_ entry: Entry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = entry.title
        attributes.displayName = entry.title
        // The line under the title in the results: the summary, else the first words.
        attributes.contentDescription = entry.summary ?? String(entry.text.prefix(200))
        attributes.textContent = entry.text
        attributes.keywords = entry.keywords
        attributes.contentCreationDate = entry.created
        attributes.duration = NSNumber(value: entry.duration)
        let item = CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture                 // the default is a month
        return item
    }
}
