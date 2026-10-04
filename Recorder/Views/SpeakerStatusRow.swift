import SwiftUI

/// The transcript's row under the tags while its speakers are not final: the progress of the words and speakers pass
/// ("Improving transcript accuracy…", "Refining speakers…"), the download note with "Try Again" when the speaker model
/// isn't there, or the failure with "Try Again".
struct SpeakerStatusRow: View {
    let recording: Recording

    @Environment(AppServices.self) private var services

    @ViewBuilder
    var body: some View {
        let preliminary = recording.speakerCount > 0     // live labels saved at Stop; the row only shows until .done
        switch recording.speakerStatus {
        case .processing:
            HStack {
                ProgressView()
                Text(services.identifier.refining.contains(recording.id) ? "Improving transcript accuracy…"
                     : preliminary ? "Refining speakers…" : "Identifying speakers…")
            }
            .foregroundStyle(.secondary)
        case .pending where services.identifier.inFlight.contains(recording.id) && services.identifier.modelError == nil:
            // Just saved and queued (or waiting behind another): it is on its way, so the progress, not a retry button
            // that read as an error for the moment before identification starts.
            HStack {
                ProgressView()
                Text(preliminary ? "Refining speakers…" : "Identifying speakers…")
            }
            .foregroundStyle(.secondary)
        case .pending:
            VStack(alignment: .leading, spacing: 8) {
                Label(services.identifier.modelError == nil
                      ? (preliminary ? "Speaker labels are preliminary and will be refined shortly."
                                     : "Speakers will be identified shortly.")
                      : (preliminary ? "Speaker labels are preliminary. They'll be refined once the speaker model (21 MB) has downloaded. Connect to the internet and try again."
                                     : "Speakers will be identified once the speaker model (21 MB) has downloaded. Connect to the internet and try again."),
                      systemImage: "person.2.wave.2")
                Button("Try Again") { services.identifier.enqueue(recording) }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label(preliminary ? "Couldn't refine speakers. The labels shown are preliminary." : "Couldn't identify speakers.",
                      systemImage: "exclamationmark.triangle")
                Button("Try Again") { services.identifier.enqueue(recording) }
            }
        case .done:
            EmptyView()
        }
    }
}
