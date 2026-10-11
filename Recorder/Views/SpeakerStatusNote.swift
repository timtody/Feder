import SwiftUI

/// The box under the tags while the speakers can't become final on their own: the download note with "Try Again"
/// when the speaker model isn't there, or the failure with "Try Again". Progress itself is the status line under the
/// date (PipelineStatusLine).
struct SpeakerStatusNote: View {
    let recording: Recording

    @Environment(AppServices.self) private var services

    /// Whether there is a note for `recording`: a `.pending` transcript nobody is working on (not queued, no progress
    /// record), a model that couldn't be downloaded, or a failed pass. A `.processing` transcript without a record
    /// (between a launch and its re-queue) shows nothing, not an empty grey box.
    static func applies(to recording: Recording, identifier: SpeakerIdentifier) -> Bool {
        switch recording.speakerStatus {
        case .done: false
        case .failed: true
        case .pending: identifier.progress[recording.id] == nil && !identifier.inFlight.contains(recording.id) || identifier.modelError != nil
        case .processing: identifier.modelError != nil
        }
    }

    var body: some View {
        let preliminary = recording.speakerCount > 0     // live labels saved at Stop
        VStack(alignment: .leading, spacing: 8) {
            if recording.speakerStatus == .failed, !recording.wordsRefined, recording.segments.isEmpty {
                // An import whose words couldn't be written (SpeakerIdentifier.identify): no live words to show.
                Label("Couldn't transcribe this recording. Its language may need a download: connect to the internet and try again.",
                      systemImage: "exclamationmark.triangle")
            } else if recording.speakerStatus == .failed {
                Label(preliminary ? "Couldn't refine speakers. The labels shown are preliminary." : "Couldn't identify speakers.",
                      systemImage: "exclamationmark.triangle")
            } else {
                Label(services.identifier.modelError == nil
                      ? (preliminary ? "Speaker labels are preliminary and will be refined shortly."
                                     : "Speakers will be identified shortly.")
                      : (preliminary ? "Speaker labels are preliminary. They'll be refined once the speaker model (21 MB) has downloaded. Connect to the internet and try again."
                                     : "Speakers will be identified once the speaker model (21 MB) has downloaded. Connect to the internet and try again."),
                      systemImage: "person.2.wave.2")
            }
            Button("Try Again") { services.identifier.enqueue(recording) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
