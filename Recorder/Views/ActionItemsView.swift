import SwiftData
import SwiftUI

/// The place of the action items under the Summary row (RecordingDetailView): while the steps after Stop run and the
/// action items are among them, a hidden folded row holds the place, so the end of the pipeline moves nothing: the
/// status line crossfades into "Summary" and the held place into "Action Items" in the same update. Once held, the place
/// stays while the card is open, an empty line when nothing was found (`keepsRow`, as the summary's). Otherwise the row
/// is there only when the transcript has action items the user didn't remove; items already there stay on screen
/// while new ones are looked for.
struct ActionItemsSlot: View {
    let recording: Recording
    /// The status line is shown (PipelineStatusLine.text).
    let statusShown: Bool
    /// The place was held while this card was open (RecordingDetailView's `keepsActionsRow`).
    let keepsRow: Bool
    /// The card's Undo for removed items (its toast and shake).
    let undo: ActionItemUndo

    @Environment(AppServices.self) private var services
    /// Here rather than in the row: the row is made anew when its last item is removed and put back (Undo), and it
    /// came back folded.
    @State private var isExpanded = false

    /// The status line is up and the action items are one of its steps, still to be found (SpeakerIdentifier lists
    /// the step only then): their place is held.
    static func reserves(_ recording: Recording, statusShown: Bool, identifier: SpeakerIdentifier) -> Bool {
        statusShown && identifier.progress[recording.id]?.state(of: .actions) != nil
            && recording.actionItemsVersion < ActionItemExtractor.version
    }

    var body: some View {
        let items = recording.actionItems                // read once per body (the SwiftData array is decoded on access)
        let shown = items.contains { !$0.isRemoved }
        let reserving = Self.reserves(recording, statusShown: statusShown, identifier: services.identifier)
        if reserving || shown || keepsRow {
            ZStack(alignment: .leading) {
                if shown {
                    ActionItemsDisclosure(recording: recording, items: items, isExpanded: $isExpanded, undo: undo)
                } else {
                    ActionItemsDisclosure.standIn
                }
            }
            .animation(.easeInOut(duration: 0.25), value: shown)
        }
    }
}

/// The card's Undo for removed action items, as for its corrections: a toast for the last removal (ActionItemUndoToast,
/// 6 s), and shaking the iPhone puts back each removal, newest first, until the card closes (the window's UndoManager:
/// a shake right after Remove takes back the Remove, not an earlier correction). Removed items are kept hidden and
/// can't be shown again otherwise.
@Observable
final class ActionItemUndo {
    /// One removal: the UndoManager's target, so the toast's Undo takes back exactly its shake action.
    final class Removal: Identifiable {
        let itemID: UUID
        let recording: Recording

        init(itemID: UUID, recording: Recording) {
            self.itemID = itemID
            self.recording = recording
        }
    }

    /// The removal the toast offers to undo, until it times out or something else takes its place.
    var toast: Removal?
    /// Every removal whose shake action is registered (the card closing takes them back).
    @ObservationIgnored private var registered: [Removal] = []

    func removed(_ itemID: UUID, in recording: Recording, undoManager: UndoManager?) {
        let removal = Removal(itemID: itemID, recording: recording)
        registered.append(removal)
        undoManager?.registerUndo(withTarget: removal) { [weak self] removal in
            MainActor.assumeIsolated { self?.undo(removal, undoManager: nil) }
        }
        undoManager?.setActionName(String(localized: "Action Item Removed"))
        toast = removal
    }

    /// Puts the item back (the toast's Undo with the UndoManager, so the shake's action goes; a shake without).
    func undo(_ removal: Removal, undoManager: UndoManager?) {
        undoManager?.removeAllActions(withTarget: removal)
        registered.removeAll { $0 === removal }
        if toast === removal { toast = nil }
        withAnimation(.snappy) {
            _ = ActionItemsDisclosure.change(removal.recording, [removal.itemID]) { $0.isRemoved = false }
        }
    }

    /// The card closed: no shake brings back an item on a card that isn't there.
    func withdraw(from undoManager: UndoManager?) {
        for removal in registered { undoManager?.removeAllActions(withTarget: removal) }
        registered = []
        toast = nil
    }
}

/// "Action Item Removed · Undo" above the bottom toolbar for 6 s, the toast of the card's corrections (UndoToast).
/// `shown` hides a correction's toast meanwhile (the card hides this one when a correction's comes).
struct ActionItemUndoToast: ViewModifier {
    let undo: ActionItemUndo
    let shown: () -> Void

    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let removal = undo.toast {
                    UndoToast(title: String(localized: "Action Item Removed"),
                              undo: { undo.undo(removal, undoManager: undoManager) },
                              identifier: "UndoRemoveActionItem")
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear { InteractionTrace.shown("remove") }
                }
            }
            .animation(.snappy, value: undo.toast?.id)
            .task(id: undo.toast?.id) {
                guard undo.toast != nil else { return }
                shown()
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                undo.toast = nil
            }
    }
}

/// A transcript's action items (ActionItemExtractor), folded into one "Action Items" row like the Summary row above it
/// (the system's `DisclosureGroup`, subheadline, the count in secondary). Opened, a row per item, the way Reminders
/// lists them: the task, under it who and by when (and "In Reminders", "In Calendar" once added), in secondary: these
/// are suggestions, often from past meetings, so a date gone by is never Reminders' overdue red. At the end of each row a
/// menu (plus.circle, a filled checkmark once added anywhere, like Music's add-to-library): Add to Reminders (one tap,
/// EventKit; once added, "Add to Reminders Again", for a reminder deleted there), Add to Calendar (Apple's New Event
/// editor to check it in), Copy, and Remove (no question: it is a suggestion; Undo in a toast and by shaking; kept
/// hidden, so a new extraction doesn't bring it back). "Add All to Reminders" under them while two or more aren't in
/// Reminders yet. No glass: content.
struct ActionItemsDisclosure: View {
    let recording: Recording
    /// All of the transcript's items, removed ones too (read once by the slot).
    let items: [ActionItem]
    @Binding var isExpanded: Bool
    let undo: ActionItemUndo

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.undoManager) private var undoManager

    /// Items being added to Reminders: a spinner in their menu's place from the press's frame on.
    @State private var adding: Set<UUID> = []
    @State private var accessDenied = false
    @State private var failure: String?
    /// Counts successful adds (the success haptic).
    @State private var added = 0

    private var visible: [ActionItem] { items.filter { !$0.isRemoved } }

    var body: some View {
        let visible = visible
        let notInReminders = visible.filter { $0.addedToReminders == nil }
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index)
                }
                if notInReminders.count >= 2 {
                    Button("Add All to Reminders") { addToReminders(notInReminders.map(\.id)) }
                        .buttonStyle(.borderless)
                        .disabled(!adding.isEmpty)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("AddAllToReminders")
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Action Items").fontWeight(.semibold)
                Text(verbatim: "\(visible.count)").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Action Items")
            .accessibilityValue(([String(visible.count)] + visible.map(\.task)).joined(separator: ", "))
            .accessibilityIdentifier("ActionItems")
        }
        .font(.subheadline)
        // The editor's store is made off the main actor while the row opens, so Add to Calendar doesn't make it.
        .task(id: isExpanded) { if isExpanded { await EventEditor.warmUp() } }
        .sensoryFeedback(.success, trigger: added)
        .alert("Allow Access to Reminders", isPresented: $accessDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To add action items, allow Feder full access to Reminders in Settings.")
        }
        .alert("Couldn't Add to Reminders", isPresented: Binding(get: { failure != nil },
                                                                set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    /// One item: the task, and under it who · by when · where it was added; the menu at the end.
    private func row(_ item: ActionItem, index: Int) -> some View {
        let caption = ActionItemText.caption(item)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver: the item as one element (task, who, when, where added), the menu's choices as its actions.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ActionItem.\(index)")
            .accessibilityActions {
                if item.addedToReminders == nil {
                    Button("Add to Reminders") { addToReminders([item.id]) }
                } else {
                    Button("Add to Reminders Again") { addToReminders([item.id]) }
                }
                Button("Add to Calendar") { addToCalendar(item) }
                Button("Copy") { copy(item) }
                Button("Remove") { remove(item) }
            }
            if adding.contains(item.id) {
                ProgressView()
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .onAppear { InteractionTrace.shown("reminders") }
            } else {
                Menu {
                    // Once added, the choice says so: one tap adds it, so not twice by mistake, and still there for a
                    // reminder deleted in Reminders (Feder reads nothing there, so it can't know).
                    if item.addedToReminders == nil {
                        Button("Add to Reminders", systemImage: "checklist") { addToReminders([item.id]) }
                    } else {
                        Button("Add to Reminders Again", systemImage: "checklist") { addToReminders([item.id]) }
                    }
                    Button("Add to Calendar", systemImage: "calendar.badge.plus") { addToCalendar(item) }
                    Button("Copy", systemImage: "doc.on.doc") { copy(item) }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { remove(item) }
                } label: {
                    // At the row's end, under the disclosure chevron (centred in its 44 pt target it stood 13 pt in).
                    Image(systemName: item.isAdded ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                // The menu holds more than adding (Copy, Remove), and the checkmark's "added" is its value.
                .accessibilityLabel(String(localized: "More for “\(item.task)”"))
                .accessibilityValue(ActionItemText.added(item) ?? "")
                .accessibilityIdentifier("ActionItemMenu.\(index)")
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: Actions

    /// Adds the items to Reminders' default list: full access is asked for the first time (iOS's alert). Don't Allow
    /// there is the answer (nothing more is said); when access was denied before, an alert offers Settings, as iOS never
    /// asks again. EventKit's work runs on ReminderWriter's actor; the press only shows the spinner.
    private func addToReminders(_ ids: [UUID]) {
        InteractionTrace.begin("reminders")
        let wanted = Set(ids)
        let drafts = items.filter { wanted.contains($0.id) }.map { ReminderDraft($0, in: recording) }
        guard !drafts.isEmpty else { return }
        adding.formUnion(wanted)
        Task {
            defer { adding.subtract(wanted) }
            do {
                switch try await ReminderWriter.shared.add(drafts) {
                case .added: break
                case .declined: return
                case .denied:
                    accessDenied = true
                    return
                }
            } catch ReminderWriter.Failure.noList {
                failure = String(localized: "There's no list in Reminders to add to.")
                return
            } catch {
                failure = error.localizedDescription
                return
            }
            // Saved at once: an item in Reminders that looked not added after a kill would be added twice.
            if Self.change(recording, wanted, { $0.addedToReminders = .now }) { try? modelContext.save() }
            added += 1
        }
    }

    /// Apple's New Event editor, prefilled; the item counts as in Calendar only when the user taps Add there.
    private func addToCalendar(_ item: ActionItem) {
        InteractionTrace.begin("calendar")
        let id = item.id
        EventEditor.present(EventDraft(item, in: recording)) {
            if Self.change(recording, [id], { $0.addedToCalendar = .now }) { try? modelContext.save() }
            added += 1
        }
    }

    private func copy(_ item: ActionItem) {
        UIPasteboard.general.string = ActionItemText.line(item)
    }

    /// No save in the press (a synchronous SQLite write): the main context autosaves, and Undo puts it back.
    private func remove(_ item: ActionItem) {
        InteractionTrace.begin("remove")
        withAnimation(.snappy) { _ = Self.change(recording, [item.id]) { $0.isRemoved = true } }
        undo.removed(item.id, in: recording, undoManager: undoManager)
    }

    /// Writes a change to the stored items (once: the array is encoded as a whole); false when the transcript was
    /// deleted meanwhile.
    @discardableResult
    static func change(_ recording: Recording, _ ids: Set<UUID>, _ update: (inout ActionItem) -> Void) -> Bool {
        guard !recording.isDeleted, recording.modelContext != nil else { return false }
        var stored = recording.actionItems
        for index in stored.indices where ids.contains(stored[index].id) { update(&stored[index]) }
        recording.actionItems = stored
        return true
    }

    /// A hidden folded row: what holds the place in the same height before there are items (or when none were found).
    static var standIn: some View {
        DisclosureGroup(isExpanded: .constant(false)) {
            EmptyView()
        } label: {
            HStack(spacing: 6) {
                Text("Action Items").fontWeight(.semibold)
                Text(verbatim: "0")
            }
        }
        .font(.subheadline)
        .hidden()
        .accessibilityHidden(true)
    }
}
