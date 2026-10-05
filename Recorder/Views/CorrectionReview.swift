import SwiftUI

/// The box under the tags while Gemma's smart corrections await review (`Recording.proposedCorrections`): one row per
/// change (the speaker, the old words struck through, the new ones), each with a checkmark that takes just that change
/// over, and "Apply All" / "Dismiss" for the whole proposal. The rows come from the live difference between the
/// transcript and the proposal (SpeakerIdentifier.proposedChanges), so an accepted row simply disappears; the last
/// one ends the review. For now the corrections are reviewed rather than applied: to see what the model does.
struct CorrectionReview: View {
    let recording: Recording

    @Environment(AppServices.self) private var services

    static func applies(to recording: Recording) -> Bool { recording.proposedCorrections != nil }

    var body: some View {
        let changes = services.identifier.proposedChanges(for: recording)
        let moves = services.identifier.proposedMoves(for: recording)
        let count = changes.count + moves.count
        VStack(alignment: .leading, spacing: 10) {
            Label(count == 1 ? "1 suggested correction" : "\(count) suggested corrections",
                  systemImage: "text.badge.checkmark")
                .font(.subheadline.weight(.semibold))
            // A fragment moved to another speaker: "Apply All" only, since one accepted change keeps the paragraphs.
            ForEach(moves) { move in
                VStack(alignment: .leading, spacing: 2) {
                    if let name = speaker(at: move.time) {
                        Text("\(name) → \(move.toSpeaker.map(recording.speakerName) ?? "Speaker")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("“\(move.words.map(\.text).joined(separator: " "))” moved")
                        .font(.callout)
                }
            }
            ForEach(changes) { change in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = speaker(at: change.time) {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(diff(change))
                            .font(.callout)
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.snappy) { services.identifier.acceptCorrection(change, in: recording) }
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Accept correction")
                    .accessibilityIdentifier("Accept correction")
                }
            }
            HStack {
                Button("Apply All") { withAnimation(.snappy) { services.identifier.applyCorrections(to: recording) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0)
                Button("Dismiss") { withAnimation(.snappy) { services.identifier.dismissCorrections(for: recording) } }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CorrectionReview")
    }

    /// "old words" struck through in grey, then the new words in the tint; one of them alone for a pure insertion or
    /// deletion.
    private func diff(_ change: CorrectionMerge.Change) -> AttributedString {
        var result = AttributedString()
        if !change.oldWords.isEmpty {
            var old = AttributedString(change.oldWords.map(\.text).joined(separator: " "))
            old.strikethroughStyle = .single
            old.foregroundColor = .secondary
            result += old
        }
        if !change.oldWords.isEmpty, !change.newWords.isEmpty { result += AttributedString("  ") }
        if !change.newWords.isEmpty {
            var new = AttributedString(change.newWords.map(\.text).joined(separator: " "))
            new.foregroundColor = .accentColor
            result += new
        } else {
            var removed = AttributedString("  (removed)")
            removed.foregroundColor = .secondary
            result += removed
        }
        return result
    }

    private func speaker(at time: TimeInterval) -> String? {
        let segment = recording.segments.last { $0.start <= time + 0.001 } ?? recording.segments.first
        return segment?.speakerIndex.map(recording.speakerName)
    }
}
