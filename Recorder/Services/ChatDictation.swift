import Foundation
import AVFoundation

/// Speaking a question to Gemma (FED-137): the card's microphone button dictates into the field with the same engine
/// as a recording's live words (Apple's SpeechTranscriber, on this iPhone; the fake on the simulator) and the same
/// capture. The capture writes its WAV, which is a temporary file here, deleted when dictation ends: nothing of it is
/// kept. Recording and dictation never overlap (both own the microphone): the card stops it when a recording starts.
@MainActor @Observable
final class ChatDictation {
    enum State: Equatable {
        case idle, preparing, listening
        case failed(String)
    }

    private(set) var state: State = .idle
    var isActive: Bool { state == .preparing || state == .listening }

    @ObservationIgnored private var capture: MicrophoneCapture?
    @ObservationIgnored private var transcriber: (any Transcriber)?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// What was said, final words and the provisional tail; the field shows the text typed before, then these.
    @ObservationIgnored private var finalized: [String] = []
    @ObservationIgnored private var volatile: [String] = []
    @ObservationIgnored private var deliver: (@MainActor (String) -> Void)?

    /// Starts listening; every update of the words goes to `onText` with the whole dictated text so far.
    func start(makeTranscriber: () -> any Transcriber, onText: @escaping @MainActor (String) -> Void) {
        guard !isActive else { return }
        state = .preparing
        finalized = []
        volatile = []
        deliver = onText
        let capture = MicrophoneCapture()
        let transcriber = makeTranscriber()
        self.capture = capture
        self.transcriber = transcriber
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await AVAudioApplication.requestRecordPermission() else {
                await end(failure: RecorderError.microphoneDenied.localizedDescription)
                return
            }
            do {
                try await capture.activateSession()
                let setup = try await transcriber.prepare(locale: TranscriptionLanguage.current) { _ in }
                guard !Task.isCancelled else { return await end() }
                let url = FileManager.default.temporaryDirectory.appending(path: "ask-\(UUID().uuidString).wav")
                fileURL = url
                let input = try await capture.start(writingTo: url, analyzerFormat: setup.audioFormat,
                                                    liveSamples: nil, levels: nil)
                try await transcriber.start(input: input) { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .volatile(let words): volatile = words.map(\.text)
                    case .finalized(let words):
                        finalized += words.map(\.text)
                        volatile = []
                    case .failed(let error):
                        Task { await self.end(failure: error.localizedDescription) }
                        return
                    }
                    deliver?((finalized + volatile).joined(separator: " "))
                }
                guard !Task.isCancelled else { return await end() }
                state = .listening
            } catch {
                await end(failure: (error as? RecorderError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }

    /// Words that arrive from now on go nowhere: a question was sent, and its field is empty again.
    func detach() { deliver = nil }

    /// The button pressed again, the card closing, or a recording starting: the last words are delivered first, so
    /// what was said just before the press is in the field.
    func stop() async {
        startTask?.cancel()
        await end()
    }

    private func end(failure: String? = nil) async {
        guard capture != nil else { return }
        let capture = capture, transcriber = transcriber, url = fileURL
        self.capture = nil
        self.transcriber = nil
        fileURL = nil
        defer { deliver = nil }                       // after finish(): its last words still arrive
        _ = capture?.seal()
        await capture?.shutDown()
        try? await transcriber?.finish()
        if let url { try? FileManager.default.removeItem(at: url) }
        state = failure.map { .failed($0) } ?? .idle
    }
}
