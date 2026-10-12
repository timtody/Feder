import Foundation
// Replays recorded SpeechTranscriber/LS-EEND events (rec) into the app's LiveTranscript, publishing like
// RecordingSession (and refreshing when nextChange comes due), and scores the live screen against the script.
struct W: Codable { var text: String; var start: Double; var end: Double }
struct T: Codable { var speaker: Int; var start: Double; var end: Double }
struct E: Codable { var t: Double; var kind: String; var words: [W]?; var turns: [T]?; var until: Double? }
struct Sentence: Codable { var speaker: Int; var text: String; var start: Double; var end: Double }
struct Truth: Codable { var turns: [T]; var sentences: [Sentence] }

func norm(_ s: Substring) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
func align(_ a: [String], _ b: [String]) -> [Int: Int] {      // b index -> a index (match or substitution)
    let n = a.count, m = b.count; guard n > 0, m > 0 else { return [:] }
    var c = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { c[i][0] = i }; for j in 0...m { c[0][j] = j }
    for i in 1...n { for j in 1...m { c[i][j] = min(c[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1), c[i-1][j] + 1, c[i][j-1] + 1) } }
    var out: [Int: Int] = [:]; var i = n, j = m
    while i > 0, j > 0 {
        if c[i][j] == c[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1) { out[j-1] = i-1; i -= 1; j -= 1 }
        else if c[i][j] == c[i-1][j] + 1 { i -= 1 } else { j -= 1 }
    }
    return out
}

struct Para { var label: Int?; var showsName = false; var idx: [Int?]
#if NAMES
 var key: LiveNames.Key? = nil
#endif
}     // per token: final word index (nil: none)

var grand = (wrong: 0.0, shown: 0.0, flick: 0, changes: 0, lat: [Double]())
for conv in CommandLine.arguments.dropFirst() {
    let events = try JSONDecoder().decode([E].self, from: Data(contentsOf: URL(fileURLWithPath: "\(conv)-events.json")))
    let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: URL(fileURLWithPath: "\(conv).json")))
    let finals = events.filter { $0.kind == "final" }.flatMap { $0.words! }
    let finalTokens = finals.map { norm(Substring($0.text)) }
    func truthSpeaker(_ w: W) -> Int {            // the sentence the word's midpoint falls in, else the nearest
        let mid = (w.start + w.end) / 2
        return truth.sentences.min { abs(($0.start + $0.end) / 2 - mid) - ($0.end - $0.start) / 2 < abs(($1.start + $1.end) / 2 - mid) - ($1.end - $1.start) / 2 }!.speaker
    }
    let speakerOfFinal = finals.map(truthSpeaker)
    // live index -> truth speaker, by overlap in the last snapshot
    let lastTurns = events.last { $0.kind == "snapshot" }!.turns!
    var overlap: [Int: [Int: Double]] = [:]
    for lt in lastTurns { for tt in truth.turns { let o = min(lt.end, tt.end) - max(lt.start, tt.start); if o > 0 { overlap[lt.speaker, default: [:]][tt.speaker, default: 0] += o } } }
    let mapping = overlap.mapValues { $0.max { $0.value < $1.value }!.key }
    // speaker-change turns: the final word indices of their first 3 words
    var changeStarts: [(speaker: Int, idx: Set<Int>, start: Double)] = []
    var prevSpeaker: Int? = nil
    for tt in truth.turns {
        if tt.speaker != prevSpeaker {
            let ids = finals.indices.filter { speakerOfFinal[$0] == tt.speaker && finals[$0].start >= tt.start - 0.3 && finals[$0].end <= tt.end + 0.3 }.prefix(3)
            if !ids.isEmpty { changeStarts.append((tt.speaker, Set(ids), tt.start)) }
        }
        prevSpeaker = tt.speaker
    }
    let base = ContinuousClock.now
    func at(_ t: Double) -> ContinuousClock.Instant { base + .microseconds(Int((t * 1e6).rounded())) }
    func secs(_ i: ContinuousClock.Instant) -> Double { let d = i - base; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    var live = LiveTranscript()
    #if NAMES
    var names = LiveNames()
    #endif
    var queue: [(Double, E?)] = events.map { ($0.t, $0) }
    var pending: Double? = nil
    var lastPublish = 0.0, lastParas: [Para] = []
    var wrong = 0.0, shown = 0.0, flick = 0, lat: [Double] = []
    var shownOnce = Set<Int>(), hidden = Set<Int>(); var hiddenAt: [Int: Double] = [:]
    func publish(_ now: Double) {
        let dt = now - lastPublish
        var visible: Int? = nil
        for p in lastParas {
            if let l = p.label { visible = mapping[l] ?? -1 }
            for i in p.idx { guard let i else { continue }; shown += dt; if visible != speakerOfFinal[i] { wrong += dt } }
        }
        lastPublish = now
        // paragraphs, as LiveTranscriptModel builds them, with final-word indices per token
        let text = live.text
        var paras: [Para] = []
        var k = 0
        for s in text.segments {
            let n = s.text.split(separator: " ").count
            paras.append(Para(label: s.speakerIndex, idx: (k..<k + n).map { $0 < finals.count ? $0 : nil })); k += n
            #if NAMES
            if paras.count - 1 < text.segmentKeys.count { paras[paras.count - 1].key = text.segmentKeys[paras.count - 1] }
            #endif
        }
        let provTokens = text.provisional.map { norm(Substring($0.word.text)) }
        // only final words already spoken by now can be what the provisional words are
        let from = min(live.words.count, finalTokens.count)
        let spoken = finals[from...].firstIndex { $0.start > now } ?? finals.count
        let map = align(Array(finalTokens[from..<max(from, spoken)]), provTokens)
        var end = text.segments.last?.end, previous = text.speaker
        for (j, p) in text.provisional.enumerated() {
            let full = paras.last.map { TranscriptAligner.isFull(String(repeating: "x ", count: $0.idx.count)) } ?? false
            let speaker = p.speaker ?? previous
            let confirmed = p.steady != nil && p.steady == speaker
            let fi = map[j].map { $0 + live.words.count }
            if SteadyLabels.continues(lastEnd: end, full: full, speaker: speaker, previous: previous, start: p.word.start) {
                paras[paras.count - 1].idx.append(fi); if confirmed { paras[paras.count - 1].label = speaker }
            } else {
                paras.append(Para(label: SteadyLabels.newLabel(speaker: speaker, previous: previous, confirmed: confirmed, full: full), idx: [fi]))
                #if NAMES
                paras[paras.count - 1].key = speaker.map { LiveNames.Key(word: p.id, speaker: $0) }
                #endif
            }
            previous = speaker; end = p.word.end
        }
        #if NAMES
        let kept = names.labels(paras.map(\.label), keys: paras.map(\.key))
        for i in paras.indices { paras[i].label = kept[i] }
        #endif
        var sp: Int? = nil
        for i in paras.indices { if let l = paras[i].label { paras[i].showsName = sp != l; sp = l } }
        lastParas = paras
        var named = Set<Int>()
        for p in paras where p.showsName {
            guard let l = p.label, let s = mapping[l] else { continue }
            let ids = Set(p.idx.compactMap { $0 })
            for (c, ch) in changeStarts.enumerated() where ch.speaker == s && !ids.isDisjoint(with: ch.idx) { named.insert(c) }
        }
        if ProcessInfo.processInfo.environment["TRACE"] != nil {
            let d = paras.suffix(5).map { p -> String in
                let ids = p.idx.compactMap { $0 }
                let t = ids.isEmpty ? "?" : "\(finals[ids.first!].text)..\(finals[ids.last!].text)(\(ids.count)w,truth \(Set(ids.map { speakerOfFinal[$0] }).sorted()))"
                return "[\(p.label.map { "L\($0)" } ?? "-")\(p.showsName ? "*" : "") \(t)]"
            }.joined(separator: " ")
            print(String(format: "%7.2f %@", now, d))
        }
        for c in changeStarts.indices {
            if named.contains(c) {
                if !shownOnce.contains(c) { lat.append(now - changeStarts[c].start); shownOnce.insert(c) }
                if hidden.contains(c) { if now - (hiddenAt[c] ?? now) >= 0.05 { flick += 1 }; hidden.remove(c); if ProcessInfo.processInfo.environment["TRACE"] != nil { print(String(format: "   SHOWN AGAIN change %d (speaker %d at %.2f)", c, changeStarts[c].speaker, changeStarts[c].start)) } }
            } else if shownOnce.contains(c), now < changeStarts[c].start + 25, !hidden.contains(c) { hidden.insert(c); hiddenAt[c] = now; if ProcessInfo.processInfo.environment["TRACE"] != nil { print(String(format: "   HIDDEN change %d (speaker %d at %.2f)", c, changeStarts[c].speaker, changeStarts[c].start)) } }
        }
        if let due = live.nextChange, pending == nil { let d = max(secs(due), now) + 0.001; pending = d; queue.append((d, nil)) }
    }
    while !queue.isEmpty {
        queue.sort { $0.0 < $1.0 }
        let (now, e) = queue.removeFirst()
        let t = at(now)
        if let e {
            switch e.kind {
            case "volatile": live.revise(e.words!.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }, now: t)
            case "final": live.finalize(e.words!.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }, now: t)
            default: live.apply(LiveSpeakerTurns(turns: e.turns!.map { SpeakerTurn(speakerIndex: $0.speaker, start: $0.start, end: $0.end) }, processedUntil: e.until!), now: t)
            }
        } else { pending = nil; live.refresh(now: t) }
        publish(now)
    }
    print(String(format: "%@: words under a wrong visible speaker %5.1f %%, name flickers %d of %d changes, mapping %@",
                 (conv as NSString).lastPathComponent, 100 * wrong / shown, flick, changeStarts.count, "\(mapping)"))
    grand.wrong += wrong; grand.shown += shown; grand.flick += flick; grand.changes += changeStarts.count; grand.lat += lat
}
let lat = grand.lat.sorted()
print(String(format: "ALL: words under a wrong visible speaker %5.1f %%, name flickers %d of %d, name after change p50 %.2f s p90 %.2f s",
             100 * grand.wrong / grand.shown, grand.flick, grand.changes, lat.isEmpty ? 0 : lat[lat.count / 2], lat.isEmpty ? 0 : lat[lat.count * 9 / 10]))
