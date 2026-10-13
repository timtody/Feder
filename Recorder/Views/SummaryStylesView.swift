import SwiftData
import SwiftUI

/// Settings › Summaries › Styles for Tags (FED-15): a summary style per tag, one row per tag in use (a Form's menu
/// picker: None or one of the five styles). Stored in UserDefaults (SummaryStyles: tags are plain strings on the
/// transcripts). A transcript with such a tag gets its summary in that style when it is written, and when the tag is
/// added to it later (RecordingDetailView), unless a style was chosen for it by hand; changing a style here rewrites
/// nothing that exists (never the archive). The tags are read after the first frame, in batches.
struct SummaryStylesView: View {
    @Environment(\.modelContext) private var modelContext
    /// The tags of every transcript, case-insensitively unique (the newest transcript's spelling), sorted as Finder
    /// sorts; nil while they are read.
    @State private var tags: [String]?
    @State private var styles = SummaryStyles.byTag

    private static let batch = 32

    var body: some View {
        Form {
            if let tags, !tags.isEmpty {
                Section {
                    ForEach(tags, id: \.self) { tag in
                        Picker(selection: binding(for: tag)) {
                            Text("None").tag(SummaryStyle?.none)
                            ForEach(SummaryStyle.allCases) { style in
                                Label(style.name, systemImage: style.symbol).tag(SummaryStyle?.some(style))
                            }
                        } label: {
                            Text(verbatim: tag)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("TagStyle.\(tag)")
                    }
                } footer: {
                    Text("A transcript with one of these tags gets its summary in that style: new transcripts, and one you add the tag to. A style you choose while recording or in the summary comes first.")
                }
            }
        }
        .overlay {
            if tags?.isEmpty == true {
                ContentUnavailableView("No Tags", systemImage: "tag",
                                       description: Text("Add tags to your transcripts, then choose a summary style for each here."))
            }
        }
        .navigationTitle("Styles for Tags")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTags() }
    }

    private func binding(for tag: String) -> Binding<SummaryStyle?> {
        Binding(get: { styles[tag.lowercased()].flatMap(SummaryStyle.init(rawValue:)) },
                set: { style in
                    SummaryStyles.set(style, forTag: tag)
                    styles = SummaryStyles.byTag
                })
    }

    /// Every transcript's tags, newest transcripts first, in batches of `batch`, one per turn of the main actor
    /// (Recording is a main-actor model; as TagEditor reads its suggestions), starting after the first frame.
    private func loadTags() async {
        var seen: Set<String> = [], found: [String] = []
        var offset = 0
        while true {
            await Task.yield()
            guard !Task.isCancelled else { return }
            var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batch
            let batch = (try? modelContext.fetch(descriptor)) ?? []
            for tag in batch.flatMap(\.tags) where seen.insert(tag.lowercased()).inserted { found.append(tag) }
            offset += batch.count
            if batch.count < Self.batch { break }
        }
        tags = found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
