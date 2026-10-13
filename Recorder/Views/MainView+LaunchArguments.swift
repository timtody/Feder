#if DEBUG
import AVFoundation
import SwiftUI
import SwiftData

extension MainView {
    /// Screenshot hooks for simulator QA and the UI tests: `-seedSamples` puts two sample transcripts with named
    /// speakers into the store (`-seedPendingSample`: also a newest one whose speakers are still being identified;
    /// `-seedFiller <n>`: n older ones, a list long enough to scroll; `-seedPersonTopics`: a third transcript of Anna's
    /// and topics, so her page has recurring topics; all simulator only, never into an iPhone's real
    /// store); `-showSettings` / `-showPeople` select the Settings tab; `-showPerson <name>` opens that person's page
    /// in Settings › People;
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
                             filler: UserDefaults.standard.integer(forKey: "seedFiller"),
                             personTopics: arguments.contains("-seedPersonTopics"))
            // `-seedInvitees "Maria Lopez|Jonas Weber"`: Project Kickoff as if started during the calendar event
            // "Kickoff Meeting" with those invitees (the rename sheet's Invitees section, without recording).
            if let invitees = UserDefaults.standard.string(forKey: "seedInvitees"),
               let kickoff = try? modelContext.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == PreviewData.kickoffID }) {
                kickoff.calendarEventTitle = "Kickoff Meeting"
                kickoff.calendarAttendees = invitees.split(separator: "|").map(String.init)
                try? modelContext.save()
            }
            // `-seedOldTranscripts`: the samples as transcripts never described and never looked for action items,
            // Budget Review ten days old: the launch sweep must write Project Kickoff's summary only, leave Budget
            // Review, beyond `SpeakerIdentifier.gemmaLookBack`, alone, and look for action items in neither (only the
            // card's Action Items button does).
            if arguments.contains("-seedOldTranscripts") {
                for recording in (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
                where [PreviewData.kickoffID, PreviewData.budgetID].contains(recording.id) {
                    recording.actionItemsVersion = 0
                    recording.summaryVersion = 0
                    if recording.id == PreviewData.budgetID { recording.createdAt = .now.addingTimeInterval(-10 * 86_400) }
                }
                try? modelContext.save()
            }
            // `-seedBookmarks`: Budget Review with four bookmarks on three sentences (its words are 0.38 s apart): 9.6 s
            // and 10.5 s, both in Anna's first sentence (one place, FED-73); 17 s, 0.7 s into Lena's reply, so the
            // sentence that just ended counts (Anna's second, across the speaker change); 25.5 s, in Anna's last sentence.
            if arguments.contains("-seedBookmarks"),
               let budget = try? modelContext.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == PreviewData.budgetID }) {
                budget.bookmarks = [9.6, 10.5, 17, 25.5]
                try? modelContext.save()
            }
            // `-seedStyledSummary`: Budget Review's summary in the Meeting style (FED-15), as Gemma's would be stored,
            // marked described, so `-fakeGemma`'s sweep leaves it: the card's headings and bullets, and the exports.
            if arguments.contains("-seedStyledSummary"),
               let budget = try? modelContext.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == PreviewData.budgetID }) {
                budget.summary = PreviewData.budgetMeetingSummary
                budget.summaryStyle = .meeting
                budget.summaryWrittenStyle = .meeting
                budget.summaryVersion = TranscriptTitler.localVersion
                try? modelContext.save()
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }   // @Query catches up first
        }
        #endif
        let newest = (try? modelContext.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt,
                                                                                                  order: .reverse)])))?.first
        if arguments.contains("-showSettings") || arguments.contains("-showPeople") { tab = .settings }
        if let name = UserDefaults.standard.string(forKey: "showPerson"),   // `-showPerson "Anna Schmidt"`: her page
           let person = try? modelContext.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.name == name })).first {
            tab = .settings
            navigation.settings = NavigationPath([SettingsRoute.people])
            navigation.settings.append(PersonRoute(id: person.id))
        }
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
            let close = UserDefaults.standard.double(forKey: "minimizeAfter")   // closes it again, as the grabber does
            if close > 0, !arguments.contains("-autoRecord") {
                do { try await Task.sleep(for: .seconds(close)) } catch { return }
                closeCard()
            }
        }
        #if targetEnvironment(simulator)
        if arguments.contains("-federRemindersReport") {      // the UI tests: what reached Reminders, then removed
            EventEditor.debugAlert("Feder Reminders", await ReminderWriter.shared.debugTakeFederReminders())
        }
        #endif
        if arguments.contains("-exportAllFormats"),
           let exported = UserDefaults.standard.string(forKey: "exportTitle").flatMap({ title in
               try? modelContext.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.name == title })).first
           }) ?? newest {
            // QA: every export format of the newest transcript (or `-exportTitle <name>`'s: Budget Review has action
            // items) into tmp/ExportQA (with timestamps), to inspect the files from the simulator's container.
            let snapshot = exported.exportSnapshot(names: true, timestamps: true, withWords: true)
            let folder = FileManager.default.temporaryDirectory.appending(path: "ExportQA")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for format in TranscriptExport.Format.allCases {
                if let url = try? await TranscriptExport.file(format, of: snapshot) {
                    try? FileManager.default.copyItem(at: url, to: folder.appending(path: url.lastPathComponent))
                }
            }
        }
        if arguments.contains("-importTestAudio") {
            // QA: as if a 12 s m4a (AAC, 44.1 kHz stereo: a format the recorder never writes) named "Interview Lena",
            // recorded a month ago, came from another app's share sheet.
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
        // `-fakeOutsidePressAfter <s>`: a start from outside that long after launch, as the Action Button's (the
        // simulator has none): while a recording runs it adds a bookmark (FED-14).
        let outside = UserDefaults.standard.double(forKey: "fakeOutsidePressAfter")
        if outside > 0 {
            Task {
                try? await Task.sleep(for: .seconds(outside))
                RecordingControl.shared.requestStart()
            }
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

    /// A 12 s AAC file of a soft tone with pauses, in the app's temporary folder, recorded a month ago as its
    /// creation-date metadata says (as a Voice Memo's does): an import is dated when it is imported, not by its file
    /// (FED-6). AVAudioFile alone stamps the file with the time it was written, so it is copied once more with the
    /// metadata (passthrough: the same AAC).
    @concurrent
    nonisolated static func makeTestAudio(named name: String, channels voiced: Set<Int> = [0, 1]) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).m4a")
        let raw = FileManager.default.temporaryDirectory.appending(path: "\(name) (raw).m4a")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000]
        do {                                                  // the file is closed at the scope's end, before it is read
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
                  let file = try? AVAudioFile(forWriting: raw, settings: settings),
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
        }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: raw), presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        let created = AVMutableMetadataItem()
        created.keySpace = .common
        created.key = AVMetadataKey.commonKeyCreationDate as NSString
        created.value = Date.now.addingTimeInterval(-30 * 86_400) as NSDate
        export.metadata = [created]
        do { try await export.export(to: url, as: .m4a) } catch { return nil }
        return url
    }
}
#endif
