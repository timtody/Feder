#if DEBUG
import AVFoundation
import SwiftUI
import SwiftData

extension MainView {
    /// Screenshot hooks for simulator QA and the UI tests: `-seedSamples` puts two sample transcripts with named
    /// speakers into the store (`-seedPendingSample`: also a newest one whose speakers are still being identified;
    /// `-seedFiller <n>`: n older ones, a list long enough to scroll; all simulator only, never into an iPhone's real
    /// store); `-showSettings` / `-showPeople` select the Settings tab;
    /// `-openFirstTranscript` opens the newest transcript's card; `-autoRecord` starts recording (the simulator's fakes
    /// then stream text and live speaker labels), and with `-autoStopAfter <seconds>` stops it again, which saves it
    /// and turns the card into it; `-minimizeAfter <seconds>` minimizes the card into the accessory after that long
    /// and reopens it 2 s later (counted into `-autoStopAfter`; with `-openFirstTranscript` it closes that card). Search: `-search <text>`, `-searchToken person:<name>` or `tag:<tag>` (several
    /// separated by commas), `-openFirstResult` (the search list opens its first result's card); `-addTag <tag>` tags
    /// the newest transcript.
    func applyLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments
        #if targetEnvironment(simulator)                   // seeds the app's own store: never on an iPhone with real data
        if arguments.contains("-seedSamples") {
            PreviewData.seed(into: modelContext, people: services.people, identifier: services.identifier,
                             pending: arguments.contains("-seedPendingSample"),
                             filler: UserDefaults.standard.integer(forKey: "seedFiller"))
            // `-seedInvitees "Maria Lopez|Jonas Weber"`: Project Kickoff as if started during the calendar event
            // "Kickoff Meeting" with those invitees (the rename sheet's Invitees section, without recording).
            if let invitees = UserDefaults.standard.string(forKey: "seedInvitees"),
               let kickoff = try? modelContext.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == PreviewData.kickoffID }) {
                kickoff.calendarEventTitle = "Kickoff Meeting"
                kickoff.calendarAttendees = invitees.split(separator: "|").map(String.init)
                try? modelContext.save()
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }   // @Query catches up first
        }
        #endif
        let newest = (try? modelContext.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt,
                                                                                                  order: .reverse)])))?.first
        if arguments.contains("-showSettings") || arguments.contains("-showPeople") { tab = .settings }
        if let name = UserDefaults.standard.string(forKey: "nameFirstSpeaker"), let newest {
            services.people.name(name, speaker: 0, in: newest)        // `-nameFirstSpeaker Julius`: as if typed
        }
        if let tag = UserDefaults.standard.string(forKey: "addTag"), let newest {
            newest.addTag(tag)                                         // `-addTag work`: as if typed in the detail
        }
        if let text = UserDefaults.standard.string(forKey: "search") {
            searchState.query = text
            tab = .search
        }
        if let list = UserDefaults.standard.string(forKey: "searchToken") {
            for token in list.split(separator: ",") {
                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { searchState.add(SearchToken(kind: parts[0] == "tag" ? .tag : .person, value: parts[1])) }
            }
            tab = .search
        }
        if arguments.contains("-openFirstTranscript"), let newest {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }   // the list (the zoom source) first
            openCard(newest, search: nil, sourceID: OpenTranscriptAction.rowSource(RecordingsListView.transcriptsList, newest))
            let count = UserDefaults.standard.integer(forKey: "speakerCount")   // `-speakerCount 3`: as if picked
            if count > 0 { services.identifier.setSpeakerCount(count, for: newest) }
            let close = UserDefaults.standard.double(forKey: "minimizeAfter")   // closes it again, as the grabber does
            if close > 0, !arguments.contains("-autoRecord") {
                do { try await Task.sleep(for: .seconds(close)) } catch { return }
                closeCard()
            }
        }
        if arguments.contains("-exportAllFormats"), let newest {
            // QA: every export format of the newest transcript into tmp/ExportQA (with timestamps), to inspect
            // the files from the simulator's container.
            let snapshot = newest.exportSnapshot(names: true, timestamps: true, withWords: true)
            let folder = FileManager.default.temporaryDirectory.appending(path: "ExportQA")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for format in TranscriptExport.Format.allCases {
                if let url = try? await TranscriptExport.file(format, of: snapshot) {
                    try? FileManager.default.copyItem(at: url, to: folder.appending(path: url.lastPathComponent))
                }
            }
        }
        if arguments.contains("-importTestAudio") {
            // QA: as if a 12 s m4a (AAC, 44.1 kHz stereo: a format the recorder never writes) named "Interview Lena"
            // came from another app's share sheet.
            // After the list is up (the UI tests' launch waits for it).
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            let first = await Self.makeTestAudio(named: "Interview Lena")
            // `-importTwoFiles`: a second file, handed over while the first is converting ("Interview Max", sound on
            // the right channel only, as from a second microphone): it waits its turn.
            let second = arguments.contains("-importTwoFiles")
                ? await Self.makeTestAudio(named: "Interview Max", channels: [1]) : nil
            if let first { importAudio(from: first) }
            if let second { importAudio(from: second) }
        }
        if let text = UserDefaults.standard.string(forKey: "openSpotlightResult") {
            // As if the first Spotlight result for `text` were tapped: once the launch's index sync has run (5 s).
            do { try await Task.sleep(for: .seconds(7)) } catch { return }
            if let id = await SpotlightIndex.debugQuery(text).first.flatMap(UUID.init(uuidString:)) { openFromOutside(id) }
        }
        guard arguments.contains("-autoRecord") else { return }
        await services.prepareLiveDiarizer()           // live labels need the model loaded before the session is made
        startRecording()
        let cycle = UserDefaults.standard.double(forKey: "minimizeAfter")   // `-minimizeAfter 3`: grabber, then accessory
        if cycle > 0 {
            do { try await Task.sleep(for: .seconds(cycle)) } catch { return }
            closeCard()                                // as the grabber does: back into the accessory
            do { try await Task.sleep(for: .seconds(2)) } catch { return }   // shrunk away by then
            openRecorder()                             // as a tap on the recording accessory does
        }
        let seconds = UserDefaults.standard.double(forKey: "autoStopAfter")
        guard seconds > 0, let session = card.session else { return }
        do { try await Task.sleep(for: .seconds(max(0, seconds - (cycle > 0 ? cycle + 2 : 0)))) } catch { return }
        await session.stop()
    }

    /// A 12 s AAC file of a soft tone with pauses, in the app's temporary folder.
    @concurrent
    nonisolated static func makeTestAudio(named name: String, channels voiced: Set<Int> = [0, 1]) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).m4a")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return nil }
        for second in 0..<12 {
            buffer.frameLength = 44_100
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                for i in 0..<44_100 {
                    let on = second % 3 != 2 && voiced.contains(channel)   // a pause every third second
                    samples[i] = on ? 0.2 * sin(2 * .pi * 220 * Float(i) / 44_100) : 0
                }
            }
            try? file.write(from: buffer)
        }
        return url
    }
}
#endif
