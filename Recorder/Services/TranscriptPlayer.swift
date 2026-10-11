import AVFoundation
import MediaPlayer
import Observation

/// Plays a transcript's audio (the WAV every recording keeps, AudioFileStore) for the card's player bar and the
/// tap-a-word-to-hear-it of the transcript: one player for the app (AppServices), on one transcript at a time.
///
/// The AVAudioPlayer and the audio session live on the `AudioHardware` actor (`PlaybackEngine`), like the recording's
/// engine: activating a session blocks, and recording and playback must not overlap, which the one actor's order
/// guarantees (a recording stops playback before it activates the session, AppServices.makeRecordingSession; while a
/// recording's capture holds the session, PlaybackEngine starts nothing, AudioSessionUse). On the main actor the
/// playhead is extrapolated from where the audio started and the clock (`time`, 20 times a second while playing), so the
/// bar and the highlighted word follow without a round trip to the audio actor per frame; only the player bar reads
/// `time`, and the transcript's paragraphs read `word`, which changes a few times a second.
///
/// Playback pauses when iOS interrupts it (a call, Siri) or the headphones go, and shows in Control Center and on the
/// lock screen (Now Playing), where it can be paused and resumed; it goes on in the background (UIBackgroundModes
/// audio). Those remote commands are on only from a Play until the player stops (a recording starts, the card closes),
/// and `mayPlay` holds for them too: the AirPods or Siri can't start a closed transcript or play into a recording.
/// Local only: nothing is streamed or shared.
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

    /// Whether playback may start (AppServices: not while a recording is being made). The bar is greyed out then; this
    /// also answers the lock screen, Control Center, the AirPods and Siri, which reach the player without the bar.
    @ObservationIgnored var mayPlay: () -> Bool = { true }

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var starts: [TimeInterval] = []
    @ObservationIgnored private var ends: [TimeInterval] = []
    /// Word time = audio time + offset (Recording.alignmentOffset: Parakeet's words lead the audio by 0.12 s).
    @ObservationIgnored private var offset: TimeInterval = 0
    /// A tapped word is the spoken one from the tap on, through the moment of audio played before it (the pre-roll),
    /// rather than the word before it (often in the paragraph above, which the transcript would scroll to).
    @ObservationIgnored private var pinned: Int?
    /// Where the playhead was at a moment (a moment ahead: the audio is heard after the output's latency).
    @ObservationIgnored private var anchor: (time: TimeInterval, at: ContinuousClock.Instant)?
    /// Counts play, pause, seek and stop: the audio actor's answer to an older request is dropped.
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let engine = PlaybackEngine()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        observeSession()
        setUpRemoteCommands()
    }

    /// Makes `recording` the transcript the bar plays (stops another one), with its words for the highlight (`words`:
    /// already read, else read here).
    func load(_ recording: Recording, words: [TranscriptWord]? = nil) {
        if recordingID != recording.id {
            stop()
            recordingID = recording.id
            url = recording.audioURL
            title = recording.name
            duration = recording.duration
            time = 0
            failed = false
        }
        setWords(words ?? recording.words, offset: recording.alignmentOffset)
    }

    /// The words changed (Edit Text, Undo, a pass after Stop): the highlight follows the new ones.
    func setWords(_ words: [TranscriptWord], offset: TimeInterval) {
        starts = words.map(\.start)
        ends = words.map(\.end)
        self.offset = offset
        if let pinned, !starts.indices.contains(pinned) { self.pinned = nil }
        updateWord()
    }

    /// The audio time a word starts at (its time without the alignment offset): where a tapped word plays from.
    func audioTime(ofWordAt start: TimeInterval) -> TimeInterval { start - offset }

    /// Plays from `start` (the playhead when nil; from the beginning once it reached the end). `word`: the tapped word
    /// it plays, highlighted from now on.
    func play(from start: TimeInterval? = nil, word tapped: Int? = nil) {
        guard let url, mayPlay() else { return }
        var from = start ?? time
        if start == nil, from >= duration - 0.05 { from = 0 }      // Play at the end: again from the beginning
        from = min(max(0, from), max(0, duration - 0.05))
        request += 1
        let id = request
        time = from
        pinned = tapped
        isPlaying = true
        failed = false
        anchor = (from, .now)
        updateWord()
        startTicking()
        setCommands(enabled: true)
        updateNowPlaying()
        let engine = engine
        Task {
            do {
                let started = try await engine.play(url: url, at: from)
                // The clock from when the audio really started (the hop and activating the session take a moment)
                // plus the output's latency (Bluetooth: ~0.2 s), so the highlight is on the word being heard.
                guard id == self.request, self.isPlaying else { return }
                self.anchor = (started.time, .now + .seconds(started.latency))
            } catch PlaybackFailure.recording {
                guard id == self.request else { return }
                self.halt()                                    // a recording holds the session: nothing played
            } catch {
                #if DEBUG
                print("[Scribe] playback: \(error)")
                #endif
                guard id == self.request, self.isPlaying else { return }
                self.halt()
                self.failed = true
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        halt()
        request += 1
        let id = request
        let engine = engine
        Task {
            // Where the audio really stopped (the clock only estimates it): Play goes on from there.
            guard let stopped = await engine.pause(), id == self.request, !self.isPlaying else { return }
            self.time = min(stopped, self.duration)
            self.updateWord()
            self.updateNowPlaying()
        }
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// Moves the playhead (the bar's slider): playback goes on from there if it was playing; at the end it stops there.
    func seek(to target: TimeInterval) {
        let to = min(max(0, target), duration)
        if isPlaying, to < duration - 0.05 {
            play(from: to)
            return
        }
        pause()
        request += 1                                           // the pause's own answer doesn't move it back
        time = to
        pinned = nil
        updateWord()
        updateNowPlaying()
    }

    /// Stops and lets go of the audio session and Now Playing (a recording starts, another transcript); the transcript
    /// stays loaded.
    func stop() {
        halt()
        request += 1
        pinned = nil
        setCommands(enabled: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let engine = engine
        Task { await engine.stop() }
    }

    /// The card closed: stopped, and nothing loaded (a remote Play has nothing to start).
    func unload() {
        stop()
        recordingID = nil
        url = nil
        starts = []
        ends = []
        word = nil
        time = 0
    }

    /// The playhead's word: the last word that started at or before it, while the playhead is inside it or in the
    /// pause after it (less than 1.5 s), so the highlight doesn't hang on a word through a long silence. A tapped word
    /// counts from the tap (`pinned`).
    private func updateWord() {
        let at = time + offset
        if let pinned, starts.indices.contains(pinned) {
            if at < starts[pinned] {
                if word != pinned { word = pinned }
                return
            }
        }
        pinned = nil
        let index = TranscriptAligner.firstIndex(in: starts) { $0 > at } - 1
        let next: Int? = index >= 0 && at < ends[index] + 1.5 ? index : nil
        if next != word { word = next }
    }

    private func halt() {
        if let anchor { time = min(duration, anchor.time + max(0, (ContinuousClock.now - anchor.at).seconds)) }
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
                let now = anchor.time + max(0, (ContinuousClock.now - anchor.at).seconds)
                if now >= self.duration {
                    self.time = self.duration
                    self.halt()
                    self.request += 1
                    self.word = nil
                    self.pinned = nil
                    self.updateNowPlaying()
                    let engine = self.engine
                    Task { _ = await engine.pause() }          // its last buffer may still be playing
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
        setCommands(enabled: false)                            // on from the first Play
    }

    /// The remote commands: on from a Play until the player stops (a recording starts, the card closes), so a press
    /// on the AirPods or "Siri, resume" never reaches a stopped player.
    private func setCommands(enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                        commands.changePlaybackPositionCommand] where command.isEnabled != enabled {
            command.isEnabled = enabled
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

nonisolated enum PlaybackFailure: Error {
    /// A recording's capture holds the audio session (AudioSessionUse).
    case recording
    /// AVAudioPlayer didn't start.
    case notStarted
}

/// The AVAudioPlayer and the session's playback category, on the audio hardware's actor (see TranscriptPlayer).
@AudioHardware
final class PlaybackEngine {
    private var player: AVAudioPlayer?
    private var url: URL?
    private var sessionActive = false

    nonisolated init() {}

    /// Plays from `time`; returns where it started and the output's latency (the audio is heard that much later).
    func play(url: URL, at time: TimeInterval) throws -> (time: TimeInterval, latency: TimeInterval) {
        // A recording's capture holds the session, from its activation until it has shut down (also after a Cancel
        // while the speech model downloads): switching the session to playback would cut the recording off.
        guard !AudioSessionUse.recording else { throw PlaybackFailure.recording }
        if self.url != url || player == nil {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            self.url = url
        }
        // Activated at every Play, not once: iOS deactivates it behind the player's back (an interruption, another
        // app's audio), and AVAudioPlayer on an inactive session plays nothing.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .spokenAudio {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
        sessionActive = true
        guard let player else { throw PlaybackFailure.notStarted }
        player.currentTime = time
        guard player.play() else { throw PlaybackFailure.notStarted }
        return (player.currentTime, session.outputLatency)
    }

    /// Pauses; returns where the audio stopped (as heard), nil when nothing was playing.
    func pause() -> TimeInterval? {
        guard let player else { return nil }
        player.pause()
        return max(0, player.currentTime - AVAudioSession.sharedInstance().outputLatency)
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
