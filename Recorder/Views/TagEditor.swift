import SwiftUI
import SwiftData

/// Tag chips with remove buttons and an "Add Tag" field. Edits the recording in place.
struct TagEditor: View {
    @Bindable var recording: Recording
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !recording.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recording.tags, id: \.self) { tag in
                            chip(tag)
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                TextField("Add Tag", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        if recording.addTag(draft) { draft = "" }
                    }
            }
        }
    }

    /// The chip's padding sits inside the button label on the trailing side, so the remove button's hit area is the
    /// whole trailing part of the capsule (~23x25 pt) rather than the bare ~10 pt glyph; the chip looks the same.
    private func chip(_ tag: String) -> some View {
        HStack(spacing: 0) {
            Text(tag)
                .padding(.leading, 10)
                .padding(.vertical, 6)
            Button {
                recording.removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove \(tag)")
        }
        .font(.subheadline)
        .background(.tint.opacity(0.12), in: Capsule())
    }
}

#if DEBUG
#Preview {
    TagEditor(recording: PreviewData.sample())
        .padding()
        .modelContainer(PreviewData.container)
}
#endif
