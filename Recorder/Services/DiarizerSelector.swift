import Foundation

/// SpeakerIdentifier's one SpeakerDiarizer. Turns come from NVIDIA Nemotron 3 (NemotronDiarizer) once its model is
/// downloaded, and from pyannote (FluidAudioDiarizer) until then, or when Nemotron fails to load or run. Voices and the
/// speaker-count clustering always use FluidAudioDiarizer's WeSpeaker models, so its 21 MB bundle is required
/// (`prepare`), Nemotron's 100 MB model is optional (NemotronModel downloads it).
nonisolated struct DiarizerSelector: SpeakerDiarizer {
    let nemotron: NemotronDiarizer
    let pyannote: FluidAudioDiarizer

    func prepare() async throws {
        try await pyannote.prepare()
    }

    func diarization(fileURL: URL, speakers: SpeakerCount) async throws -> Diarization {
        if NemotronDiarizer.isDownloaded {
            do {
                let turns = try await nemotron.diarize(fileURL: fileURL)
                guard case .exactly(let count) = speakers, !turns.isEmpty,
                      count != Set(turns.map(\.speakerIndex)).count else {        // the count already holds
                    return Diarization(turns: turns, diarizer: .nemotron)
                }
                let pieces = SpeakerClustering.pieces(of: turns)
                let embeddings = try await pyannote.embeddings(fileURL: fileURL, spans: pieces.map(\.span))
                return Diarization(turns: await Self.regroup(turns, pieces: pieces, embeddings: embeddings, clusters: count),
                                   diarizer: .nemotron)
            } catch {
                #if DEBUG
                print("[Scribe] Nemotron diarization failed, using pyannote: \(error.localizedDescription)")
                #endif
            }
        }
        return Diarization(turns: try await pyannote.diarize(fileURL: fileURL, speakers: speakers), diarizer: .pyannote)
    }

    func voices(fileURL: URL, windows: [Int: [VoiceWindows.Window]]) async throws -> [Int: SpeakerVoice] {
        try await pyannote.voices(fileURL: fileURL, windows: windows)
    }

    /// Off the main actor: average linkage is cubic in the number of pieces (hundreds in an hour-long meeting).
    @concurrent
    private static func regroup(_ turns: [SpeakerTurn], pieces: [SpeakerClustering.Piece], embeddings: [[Float]],
                                clusters: Int) async -> [SpeakerTurn] {
        SpeakerClustering.regroup(turns, pieces: pieces, embeddings: embeddings, clusters: clusters)
    }
}
