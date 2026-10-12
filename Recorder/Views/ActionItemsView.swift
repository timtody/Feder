import SwiftData
import SwiftUI

/// The card's Action Items (the bottom toolbar's checklist, where the speaker-count menu was until October 2026): Gemma
/// looks for a transcript's action items only when asked. It did so after every recording, and found tasks where nobody
/// gave one (the user's decision). A sheet, as Notes and Mail show a tool's result: opened on a transcript Gemma never
/// looked at, it asks at once and says so; with items found before, they are there at once, and Find Again asks once
/// more (what was added or removed stays: ActionItem.merged). Closing it doesn't stop Gemma
/// (SpeakerIdentifier.actionItemsSearch), and the items are kept with the transcript (exports, Spotlight). Without
/// Gemma, while recording, or stopped by leaving the app, it says so instead. Export: each item's menu (Add to
/// Reminders, Add to Calendar, Copy, Remove), Add All to Reminders, and Share for the list as text.
struct ActionItemsSheet: View {
    let recording: Recording
    /// The card's: a removal's Undo outlives the sheet (ActionItemUndo).
    let undo: ActionItemUndo

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Gemma never looked (`actionItemsVersion` 0) and nothing is stored: opening the sheet asks.
    private var neverLooked: Bool { recording.actionItemsVersion == 0 && recording.actionItems.isEmpty }

    var body: some View {
        let search = services.identifier.actionItemsSearch[recording.id]
        let items = recording.actionItems                // read once per body (the SwiftData array is decoded on access)
        let visible = items.filter { !$0.isRemoved }
        let finding = search == .running || (search == nil && neverLooked)
        NavigationStack {
            Group {
                if finding {
                    ProgressView("Finding action items…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("FindingActionItems")
                } else if let search {
                    problem(search)
                } else if visible.isEmpty {
                    ContentUnavailableView("No Action Items", systemImage: "checklist",
                                           description: Text("Gemma found no tasks in this transcript."))
                } else {
                    ActionItemsList(recording: recording, items: items, undo: undo)
                }
            }
            .navigationTitle("Action Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("CloseActionItems")
                }
                if !finding, search == nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if services.betterSummaries.activeModel != nil {     // only when it can run now
                            Button("Find Again", systemImage: "arrow.clockwise", action: find)
                        }
                        if !visible.isEmpty {
                            Button("Share", systemImage: "square.and.arrow.up") {
                                ShareSheet.present(text: ActionItemText.list(visible, transcript: recording.name),
                                                   title: String(localized: "Action Items"))
                            }
                        }
                    }
                }
            }
        }
        .modifier(ActionItemUndoToast(undo: undo))
        .presentationDetents([.medium, .large])
        .onAppear { InteractionTrace.shown("actions") }
        .task {
            // After the press's frame (the search reads the transcript's paragraphs). Never looked: ask, also after a
            // search that ended without a result (a running one goes on); else the stored items, not an old problem.
            if neverLooked { find() } else { services.identifier.forgetActionItemsProblem(of: recording.id) }
        }
        .onDisappear { undo.toast = nil }                  // the toast is the sheet's; the shake's Undo stays
    }

    private func find() {
        services.identifier.findActionItems(in: recording)
    }

    @ViewBuilder
    private func problem(_ search: SpeakerIdentifier.ActionItemsSearch) -> some View {
        switch search {
        case .running:
            EmptyView()
        case .needsGemma:
            ContentUnavailableView("Gemma Needed", systemImage: "checklist",
                                   description: Text("Gemma, the summary model, finds action items on this iPhone. Download it or turn it on in Settings › Summaries."))
        case .afterRecording:
            ContentUnavailableView("Recording in Progress", systemImage: "waveform",
                                   description: Text("Action items can be found once the recording has ended."))
        case .stopped:
            ContentUnavailableView {
                Label("Not Finished", systemImage: "checklist")
            } description: {
                Text("Feder stopped looking for action items when you left the app.")
            } actions: {
                Button("Try Again", action: find)
            }
        }
    }
}

/// The card's Undo for action items removed in its sheet, as for its corrections: a toast in the sheet for the last
/// removal (ActionItemUndoToast, 6 s), and shaking the iPhone puts back each removal, newest first, until the card
/// closes (the window's UndoManager: a shake right after Remove takes back the Remove, not an earlier correction). The
/// card owns it, not the sheet: withdrawn when the sheet closed, the removal left an empty step on the UndoManager, and
/// the next shake (⌘Z on the simulator) did nothing; only the one after it undid the correction. So the sheet closed,
/// a shake still brings the item back first. Removed items are kept hidden and can't be shown again otherwise.
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
            _ = ActionItemsList.change(removal.recording, [removal.itemID]) { $0.isRemoved = false }
        }
    }

    /// The card closed: no shake brings back an item on a card that isn't there.
    func withdraw(from undoManager: UndoManager?) {
        for removal in registered { undoManager?.removeAllActions(withTarget: removal) }
        registered = []
        toast = nil
    }
}

/// "Action Item Removed · Undo" at the bottom of the Action Items sheet for 6 s, the toast of the card's corrections
/// (UndoToast).
struct ActionItemUndoToast: ViewModifier {
    let undo: ActionItemUndo

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
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                undo.toast = nil
            }
    }
}

/// A transcript's action items (ActionItemExtractor) in the Action Items sheet, the way Reminders lists them: the task,
/// under it who and by when (and "In Reminders", "In Calendar" once added), in secondary: these are suggestions, often
/// from past meetings, so a date gone by is never Reminders' overdue red. At the end of each row a menu (plus.circle, a
/// filled checkmark once added anywhere, like Music's add-to-library): Add to Reminders (one tap, EventKit; once added,
/// "Add to Reminders Again", for a reminder deleted there), Add to Calendar (Apple's New Event editor to check it in),
/// Copy, and Remove (no question: it is a suggestion; also by swiping; Undo in a toast and by shaking; kept hidden, so
/// Find Again doesn't bring it back). "Add All to Reminders" under them while two or more aren't in Reminders yet.
struct ActionItemsList: View {
    let recording: Recording
    /// All of the transcript's items, removed ones too (read once by the sheet).
    let items: [ActionItem]
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

    var body: some View {
        let visible = items.filter { !$0.isRemoved }
        let notInReminders = visible.filter { $0.addedToReminders == nil }
        List {
            Section {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index)
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(item) }
                        }
                }
            } footer: {
                Text("AI-generated content can contain mistakes.")
            }
            if notInReminders.count >= 2 {
                Section {
                    Button("Add All to Reminders") { addToReminders(notInReminders.map(\.id)) }
                        .disabled(!adding.isEmpty)
                        .accessibilityIdentifier("AddAllToReminders")
                }
            }
        }
        // The editor's store is made off the main actor while the sheet opens, so Add to Calendar doesn't make it.
        .task { await EventEditor.warmUp() }
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
                    // At the row's end, like Reminders' info button.
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
}
