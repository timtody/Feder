import AVFoundation
import MediaPlayer
import Observation

/// Plays a transcript's audio (the WAV every recording keeps, AudioFileStore) for the card's player bar and the
/// tap-a-word-to-hear-it of the transcript: one player for the app (AppServices), on one transcript at a time.
///
/// The AVAudioPlayer and the audio session live on the `AudioHardware` actor (`PlaybackEngine`), like the recording's
/// engine: activating a session blocks, and recording and playback must not overlap, which the one actor's order
/// guarantees (a recording stops playback before it activates the session, AppServices.makeRecordingSession). On the
/// main actor the playhead is extrapolated from where playback started and the clock (`time`, 20 times a second while
/// playing), so the bar and the highlighted word follow without a round trip to the audio actor per frame; only the
/// player bar reads `time`, and the transcript reads `word`, which changes a few times a second.
///
/// Playback pauses when iOS interrupts it (a call, Siri) or the headphones go, and shows in Control Center and on the
/// lock screen (Now Playing), where it can be paused and resumed; it goes on in the background (UIBackgroundModes
/// audio). Local only: nothing is streamed or shared.
@MainActor @Observable
final class TranscriptPlayer {
    /// The transcript loaded (nil: none).
    private(set) var recordingID: UUID?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    /// The playhead, in seconds of the file.
    private(set) var time: TimeInterval = 0
    /// The index into the loaded words of the word at the playhead (the one the transcript highlights), nil before
    /// the first word or between loads.
    private(set) var word: Int?
    /// The last playback failure (the file is gone or unreadable), shown by the bar.
    private(set) var failed = false

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var starts: [TimeInterval] = []
    @ObservationIgnored private var ends: [TimeInterval] = []
    @ObservationIgnored private var anchor: (time: TimeInterval, at: ContinuousClock.Instant)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let engine = PlaybackEngine()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        observeSession()
        setUpRemoteCommands()
    }

    /// Makes `recording` the transcript the bar plays (stops another one); its words for the highlight.
    func load(_ recording: Recording) {
        if recordingID != recording.id {
            stop()
            recordingID = recording.id
            url = recording.audioURL
            title = recording.name
            duration = recording.duration
            time = 0
            failed = false
        }
        setWords(recording.words)
    }

    /// The words changed (Edit Text, Undo, a pass after Stop): the highlight follows the new ones.
    func setWords(_ words: [TranscriptWord]) {
        starts = words.map(\.start)
        ends = words.map(\.end)
        updateWord()
    }

    /// Plays from `start` (the playhead when nil; from the beginning once it reached the end).
    func play(from start: TimeInterval? = nil) {
        guard let url else { return }
        var from = start ?? time
        if from >= duration - 0.05 { from = 0 }
        from = min(max(0, from), max(0, duration - 0.05))
        time = from
        isPlaying = true
        failed = false
        anchor = (from, .now)
        updateWord()
        startTicking()
        updateNowPlaying()
        let engine = engine
        Task {
            do {
                try await engine.play(url: url, at: from)
            } catch {
                #if DEBUG
                print("[Scribe] playback: \(error)")
                #endif
                guard self.isPlaying else { return }
                self.halt()
                self.failed = true
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        halt()
        let engine = engine
        Task { await engine.pause() }
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// Moves the playhead (the bar's slider): playback goes on from there if it was playing.
    func seek(to target: TimeInterval) {
        let to = min(max(0, target), duration)
        if isPlaying {
            play(from: to)
        } else {
            time = to
            updateWord()
            updateNowPlaying()
        }
    }

    /// Stops and lets go of the audio session and Now Playing (the card closed, a recording starts, another transcript).
    func stop() {
        halt()
        let engine = engine
        Task { await engine.stop() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// The playhead's word: the last word that started at or before it, while the playhead is inside it or in the
    /// pause after it (less than 1.5 s), so the highlight doesn't hang on a word through a long silence.
    private func updateWord() {
        let index = TranscriptAligner.firstIndex(in: starts) { $0 > time } - 1
        let next: Int? = index >= 0 && time < ends[index] + 1.5 ? index : nil
        if next != word { word = next }
    }

    private func halt() {
        if let anchor { time = min(duration, anchor.time + (ContinuousClock.now - anchor.at).seconds) }
        anchor = nil
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let anchor = self.anchor else { return }
                let now = anchor.time + (ContinuousClock.now - anchor.at).seconds
                if now >= self.duration {
                    self.time = self.duration
                    self.halt()
                    self.word = nil
                    self.updateNowPlaying()
                    return
                }
                self.time = now
                self.updateWord()
            }
        }
    }

    // MARK: System

    /// Interruptions (a call, Siri) and the headphones going away pause playback, as in every player.
    private func observeSession() {
        let center = NotificationCenter.default
        let inactive: Notification.Name
        if #available(iOS 27.0, *) {
            inactive = AVAudioSession.didBecomeInactiveNotification
        } else {
            inactive = AVAudioSession.interruptionNotification
        }
        observers.append(center.addObserver(forName: inactive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        })
    }

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard recordingID != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Feder",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (whole, fraction) = components
        return TimeInterval(whole) + TimeInterval(fraction) / 1e18
    }
}

/// The AVAudioPlayer and the session's playback category, on the audio hardware's actor (see TranscriptPlayer).
@AudioHardware
final class PlaybackEngine {
    private var player: AVAudioPlayer?
    private var url: URL?
    private var sessionActive = false

    nonisolated init() {}

    func play(url: URL, at time: TimeInterval) throws {
        if self.url != url || player == nil {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            self.url = url
        }
        if !sessionActive {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            sessionActive = true
        }
        player?.currentTime = time
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
