import SwiftData
import SwiftUI

/// The place of the action items under the Summary row (RecordingDetailView): while the steps after Stop run and the
/// action items are among them, a hidden folded row holds the place, so the end of the pipeline moves nothing: the
/// status line crossfades into "Summary" and the held place into "Action Items" in the same update. Once held, the place
/// stays while the card is open, an empty line when nothing was found (`keepsRow`, as the summary's). Otherwise the row
/// is there only when the transcript has action items the user didn't remove.
struct ActionItemsSlot: View {
    let recording: Recording
    /// The status line is shown (PipelineStatusLine.text).
    let statusShown: Bool
    /// The place was held while this card was open (RecordingDetailView's `keepsActionsRow`).
    let keepsRow: Bool

    @Environment(AppServices.self) private var services

    /// The status line is up and the action items are one of its steps: their place is held.
    static func reserves(_ recording: Recording, statusShown: Bool, identifier: SpeakerIdentifier) -> Bool {
        statusShown && identifier.progress[recording.id]?.state(of: .actions) != nil
    }

    var body: some View {
        let items = recording.actionItems                // read once per body (the SwiftData array is decoded on access)
        let shown = items.contains { !$0.isRemoved }
        let reserving = Self.reserves(recording, statusShown: statusShown, identifier: services.identifier)
        if reserving || shown || keepsRow {
            ZStack(alignment: .leading) {
                if reserving || !shown {
                    ActionItemsDisclosure.standIn
                }
                if !reserving, shown {
                    ActionItemsDisclosure(recording: recording, items: items)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: reserving)
        }
    }
}

/// A transcript's action items (ActionItemExtractor), folded into one "Action Items" row like the Summary row above it
/// (the system's `DisclosureGroup`, subheadline, the count in secondary). Opened, a row per item, the way Reminders
/// lists them: the task, under it who and by when (and "In Reminders", "In Calendar" once added), in secondary: these
/// are suggestions, often from past meetings, so a date gone by is never Reminders' overdue red. At the end of each row a
/// menu (plus.circle, a filled checkmark once added anywhere, like Music's add-to-library): Add to Reminders (one tap,
/// EventKit), Add to Calendar (Apple's New Event editor to check it in), Copy, and Remove (no question: it is a
/// suggestion; kept hidden, so a new extraction doesn't bring it back). "Add All to Reminders" under them while two or
/// more aren't in Reminders yet. No glass: content.
struct ActionItemsDisclosure: View {
    let recording: Recording
    /// All of the transcript's items, removed ones too (read once by the slot).
    let items: [ActionItem]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @State private var isExpanded = false
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
                }
                Button("Add to Calendar") { addToCalendar(item) }
                Button("Copy") { copy(item) }
                Button("Remove") { remove(item) }
            }
            if adding.contains(item.id) {
                ProgressView()
                    .frame(width: 44, height: 44)
                    .onAppear { InteractionTrace.shown("reminders") }
            } else {
                Menu {
                    Button("Add to Reminders", systemImage: "checklist") { addToReminders([item.id]) }
                        .disabled(item.addedToReminders != nil)     // one tap adds it: not twice by mistake
                    Button("Add to Calendar", systemImage: "calendar.badge.plus") { addToCalendar(item) }
                    Button("Copy", systemImage: "doc.on.doc") { copy(item) }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { remove(item) }
                } label: {
                    Image(systemName: item.isAdded ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Add “\(item.task)” to Reminders or Calendar"))
                .accessibilityIdentifier("ActionItemMenu.\(index)")
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: Actions

    /// Adds the items to Reminders' default list: full access is asked for the first time (iOS's alert), and when it was
    /// denied, an alert offers Settings (iOS never asks again). EventKit's work runs on ReminderWriter's actor; the press
    /// only shows the spinner.
    private func addToReminders(_ ids: [UUID]) {
        InteractionTrace.begin("reminders")
        let wanted = Set(ids)
        let drafts = items.filter { wanted.contains($0.id) }.map { ReminderDraft($0, in: recording) }
        guard !drafts.isEmpty else { return }
        adding.formUnion(wanted)
        Task {
            defer { adding.subtract(wanted) }
            do {
                guard try await ReminderWriter.shared.add(drafts) else {
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
            change(wanted) { $0.addedToReminders = .now }
            added += 1
        }
    }

    /// Apple's New Event editor, prefilled; the item counts as in Calendar only when the user taps Add there.
    private func addToCalendar(_ item: ActionItem) {
        InteractionTrace.begin("calendar")
        let id = item.id
        EventEditor.present(EventDraft(item, in: recording)) {
            change([id]) { $0.addedToCalendar = .now }
            added += 1
        }
    }

    private func copy(_ item: ActionItem) {
        UIPasteboard.general.string = ActionItemText.line(item)
    }

    private func remove(_ item: ActionItem) {
        withAnimation(.snappy) { change([item.id]) { $0.isRemoved = true } }
    }

    /// Writes a change to the stored items (once: the array is encoded as a whole).
    private func change(_ ids: Set<UUID>, _ update: (inout ActionItem) -> Void) {
        guard !recording.isDeleted, recording.modelContext != nil else { return }   // deleted meanwhile
        var stored = recording.actionItems
        for index in stored.indices where ids.contains(stored[index].id) { update(&stored[index]) }
        recording.actionItems = stored
        try? modelContext.save()
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
