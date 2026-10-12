import Foundation
import NaturalLanguage

/// What a person's page shows of one transcript: their longest turn there, as the start of its first paragraph (≤ 120
/// characters, `Snippets.excerpt`), the id of that turn's first paragraph (where the card opens: `TranscriptSearchContext`
/// steps through turn starts only) and how many turns they have there.
nonisolated struct PersonQuote: Sendable, Equatable {
    var text: String
    var turnStart: UUID
    var turns: Int
}

/// A recurring topic on a person's page: a tag of theirs or a word from their transcripts' topics, with the number of
/// their transcripts it comes up in.
nonisolated struct PersonTopic: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable { case tag, word }
    var kind: Kind
    var name: String                 // the spelling shown: the one most of their transcripts use
    var count: Int
    /// What a word's search looks for, in the shown spelling's case: a form that starts a spelling in each of the
    /// transcripts counted (the search matches inside words), the shortest such base form ("licence" for "licences",
    /// the lemma "Lizenz" for "Lizenzen": the plural would miss the singular), else the start all their spellings share
    /// ("strateg" for "strategies" and "Strategy"); never a lemma spelled differently ("Firma" for "Firmen" finds
    /// neither). `PersonDigest.query`.
    var query: String
    var id: String { "\(kind == .tag ? "tag" : "word"):\(SearchFolding.fold(name))" }
}

/// Pure helpers of the person page (PersonPageModel reads the transcripts on the main actor, these run off it).
///
/// **Quotes**: a turn is consecutive paragraphs of one of the person's speakers (usually one speaker per transcript,
/// two when they were split); their longest by words is quoted, the earliest on a tie.
///
/// **Topics** come from what Gemma already writes (no model runs for the page): each transcript's "Topics:" line
/// (`Recording.topics`; for transcripts described before it was kept, their summary) plus its title when the user or
/// Gemma gave it one. NLTagger takes the nouns and names out of that text (the Topics line's phrases differ from one
/// transcript to the next, so recurrence is counted on words, not phrases): a noun by its lemma when the two share
/// their start (`base`; "Daten" stays "Daten", not "Datum", a different word), folded; names are
/// kept, since NLTagger calls some nouns names (measured on macOS 27: "Lizenzbudget" at the start of a topic line was a
/// PersonalName), but the words of people's and speakers' names are dropped. Short, numeric and generic words go (a
/// small English and German stoplist), and a plural NLTagger has no lemma for ("licences", genitive "Lizenzbudgets",
/// German "-en"/"-n") is merged into its singular when both occur. Where the system has no word classes for the
/// language (the simulator; possibly a language on an iPhone), the words of the Topics line and the title stand in,
/// function words dropped (`fallbackTerms`). A word or tag is recurring when it is in at least
/// two of the person's transcripts; with ten or more other transcripts it must also be at least 1.5 times as frequent
/// among theirs as among the others (lift: nouns every conversation has drop out), ranked by `a · log2(1 + lift)`.
/// Small archives make lift meaningless, so there it is the count. Starting values, to be tuned on real archives.
nonisolated enum PersonDigest {
    /// A transcript's words for the topics: the folded key, the spelling it was written in and its base form (a noun's
    /// lemma, else that spelling), each key once, in order.
    struct Term: Sendable, Hashable {
        var key: String
        var surface: String
        var base: String
    }

    /// One transcript's segments and the person's speakers there, read on the main actor.
    struct QuoteSource: Sendable {
        var id: UUID
        var speakers: Set<Int>
        var segments: [SearchDocument.Segment]
    }

    /// One transcript's topic text, read on the main actor: Gemma's Topics line, else (described before it was kept)
    /// its summary, and its title unless it is still a name the app gave it.
    struct TermSource: Sendable, Hashable {
        var id: UUID
        var topics: [String] = []
        var summary: String?
        var title: String?

        /// What the tagger reads.
        var text: String {
            let main = topics.isEmpty ? summary ?? "" : topics.joined(separator: "; ")
            return [main, title ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
        }

        /// What the fallback without a tagger reads: noun phrases only (the Topics line's items, the title), not a
        /// summary's sentences, whose verbs and adjectives it couldn't tell from nouns.
        var phrases: String {
            (topics + [title ?? ""]).filter { !$0.isEmpty }.joined(separator: "; ")
        }
    }

    /// One finished transcript, as the ranking sees it.
    struct TopicSource: Sendable {
        var isTheirs: Bool
        var terms: [Term]
        var tags: [String]
        /// Folded words of this transcript's speaker names (a name is no topic).
        var names: Set<String>
    }

    static let minimumTranscripts = 2
    static let minimumLift = 1.5
    /// Others needed before lift counts: with fewer, a word in two of theirs and one other would be "common".
    static let liftFromOthers = 10
    static let maxTags = 3
    static let maxTopics = 8
    /// The Import tag, folded: in the language of the moment and in English (the same word in German).
    static let importTagKeys: Set<String> = [SearchFolding.fold(Recording.importTag), "import"]

    // MARK: Quotes

    static func quote(_ segments: [SearchDocument.Segment], speakers: Set<Int>) -> PersonQuote? {
        var best: (text: String, words: Int, start: UUID)?
        var turns = 0
        var i = 0
        while i < segments.count {
            guard let speaker = segments[i].speakerIndex, speakers.contains(speaker) else { i += 1; continue }
            let start = segments[i].id
            var parts: [String] = []
            while i < segments.count, segments[i].speakerIndex == speaker {
                parts.append(segments[i].text)
                i += 1
            }
            turns += 1
            let text = parts.joined(separator: " ")
            let words = text.split(whereSeparator: \.isWhitespace).count
            if words > (best?.words ?? 0) { best = (text, words, start) }
        }
        guard let best else { return nil }
        return PersonQuote(text: Snippets.excerpt(of: best.text, around: nil), turnStart: best.start, turns: turns)
    }

    /// Off the main actor: under NonisolatedNonsendingByDefault a plain `nonisolated async` function would run on the
    /// caller's actor (the main actor), so `@concurrent` is what moves the work to the global executor.
    @concurrent static func quotesInBackground(_ sources: [QuoteSource]) async -> [(id: UUID, quote: PersonQuote?)] {
        sources.map { ($0.id, quote($0.segments, speakers: $0.speakers)) }
    }

    // MARK: Topic words

    /// The nouns and names of a topic text (see the type's comment), each key once, in order.
    static func terms(in text: String) -> [Term] {
        terms(in: [TermSource(id: UUID(), summary: text)])[0]
    }

    /// The terms of each source, with one tagger for all of them (it is not Sendable, so it lives in this call). The
    /// tagger tells each text's language itself, also a three-word topic line (macOS 27). 500 short English and German
    /// texts: 0.14 s on an M5 Mac (-O); a tagger per text took 1.6 s, and an NLLanguageRecognizer per text to set the
    /// language explicitly about 1 s.
    /// Where the system has no word classes for the text's language (the iOS 27 simulator offers only the Language,
    /// Script and TokenType schemes, so every word was "OtherWord"; an iPhone could lack a language's model too, and the
    /// app downloads nothing for it), `fallbackTerms` reads the noun phrases instead.
    static func terms(in sources: [TermSource]) -> [[Term]] {
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        let tokenizer = NLTokenizer(unit: .word)
        var classified: [NLLanguage: Bool] = [:]
        func hasWordClasses(_ language: NLLanguage) -> Bool {
            if let known = classified[language] { return known }
            let has = NLTagger.availableTagSchemes(for: .word, language: language).contains(.nameTypeOrLexicalClass)
            classified[language] = has
            return has
        }
        return sources.map { source in
            let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            tagger.string = text
            let language = tagger.dominantLanguage
            guard hasWordClasses(language ?? .english) else {
                return fallbackTerms(source.phrases, german: language == .german, tokenizer: tokenizer)
            }
            let whole = text.startIndex..<text.endIndex
            var result: [Term] = []
            var seen = Set<String>()
            tagger.enumerateTags(in: whole, unit: .word, scheme: .nameTypeOrLexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                guard let tag, keptTags.contains(tag) else { return true }
                let surface = String(text[range])
                var base = surface
                if tag == .noun, let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue,
                   sharesStart(surface, lemma) {
                    base = lemma
                }
                let key = SearchFolding.fold(base)
                if isTopicWord(key), seen.insert(key).inserted {
                    result.append(Term(key: key, surface: surface, base: base))
                }
                return true
            }
            return result
        }
    }

    /// Without word classes: the words of the noun phrases (the Topics line's items and the title) that are not
    /// function words, and in German only capitalized ones (German nouns are). No lemmas: the plural merge still joins
    /// "licence" and "licences".
    static func fallbackTerms(_ phrases: String, german: Bool, tokenizer: NLTokenizer) -> [Term] {
        tokenizer.string = phrases
        var result: [Term] = []
        var seen = Set<String>()
        tokenizer.enumerateTokens(in: phrases.startIndex..<phrases.endIndex) { range, _ in
            let surface = String(phrases[range])
            let key = SearchFolding.fold(surface)
            guard !german || surface.first?.isUppercase == true, isTopicWord(key), !functionWords.contains(key),
                  seen.insert(key).inserted else { return true }
            result.append(Term(key: key, surface: surface, base: surface))
            return true
        }
        return result
    }

    /// The lemma stands for the word when it starts it ("Lizenz" for "Lizenzen", "Vertrag" for "Verträge", folded) or
    /// the two share at least 4 letters ("strategy"/"strategies", "Firma"/"Firmen", "Risiko"/"Risiken"; the chip then
    /// searches what they share). Measured on macOS 27: NLTagger's lemma of "Daten" is "Datum" (date), and of "data" in
    /// a topic line it took for French, "dater"; such a lemma would merge different words and give the chip a search
    /// that finds neither, so the word keeps its own spelling.
    static func sharesStart(_ surface: String, _ lemma: String) -> Bool {
        let word = SearchFolding.fold(surface), base = SearchFolding.fold(lemma)
        guard !base.isEmpty else { return false }
        return word.hasPrefix(base) || word.commonPrefix(with: base).count >= 4
    }

    @concurrent static func termsInBackground(_ sources: [TermSource]) async -> [(id: UUID, terms: [Term])] {
        Array(zip(sources.map(\.id), terms(in: sources)))
    }

    private static let keptTags: Set<NLTag> = [.noun, .placeName, .organizationName, .personalName]

    /// English and German words of three or more letters that are no topic: articles, pronouns, prepositions,
    /// conjunctions, auxiliaries and common adjectives (folded). Only for the fallback without word classes.
    static let functionWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "about", "over", "under", "after", "before", "until",
        "this", "that", "these", "those", "their", "they", "them", "his", "her", "its", "our", "your", "you",
        "are", "was", "were", "been", "being", "has", "have", "had", "does", "did", "will", "would", "should",
        "could", "can", "may", "might", "must", "not", "but", "nor", "yet", "also", "just", "only", "very", "more",
        "most", "less", "all", "any", "some", "each", "other", "new", "old", "next", "last", "first", "second",
        "via", "per", "between", "within", "without", "against", "during", "through", "how", "what", "when", "where",
        "who", "why", "which",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines", "einem", "einen", "und", "oder",
        "aber", "mit", "von", "fur", "auf", "aus", "bei", "nach", "zum", "zur", "uber", "unter", "vor", "gegen",
        "ohne", "durch", "zwischen", "wahrend", "bis", "seit", "ist", "sind", "war", "waren", "wird", "werden",
        "wurde", "hat", "haben", "hatte", "nicht", "kein", "keine", "sich", "sie", "wir", "ihr", "ihre", "auch",
        "noch", "nur", "dass", "wie", "als", "neue", "neuer", "neues", "neuen", "erste", "ersten", "nachste",
        "nachsten", "weitere", "weiteren", "allgemeine", "allgemeines",
    ]

    static func isTopicWord(_ key: String) -> Bool {
        key.count >= 3 && !key.allSatisfy(\.isNumber) && !stopwords.contains(key)
    }

    /// Generic words a conversation's topics are full of, folded (English and German): weekdays, months, time words,
    /// what every meeting has (people, questions, points) and generic title words.
    static let stopwords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december", "januar", "februar", "marz", "mai", "juni", "juli", "oktober", "dezember",
        "today", "tomorrow", "yesterday", "heute", "morgen", "gestern",
        "day", "days", "week", "weeks", "month", "months", "year", "years", "time", "times",
        "tag", "tage", "woche", "wochen", "monat", "monate", "jahr", "jahre", "jahres", "zeit",
        "thing", "things", "part", "parts", "number", "numbers", "people", "person", "persons",
        "sache", "sachen", "ding", "dinge", "teil", "teile", "zahl", "zahlen", "leute", "personen",
        "participant", "participants", "speaker", "speakers", "teilnehmer", "teilnehmerin", "teilnehmende",
        "sprecher", "sprecherin",
        "meeting", "meetings", "conversation", "conversations", "discussion", "discussions", "call", "calls",
        "besprechung", "besprechungen", "gesprach", "gesprache", "diskussion", "telefonat",
        "topic", "topics", "question", "questions", "point", "points", "summary", "title",
        "thema", "themen", "frage", "fragen", "punkt", "punkte", "zusammenfassung", "titel",
        // Generic title words ("Budget Review", "Hiring Plan", "Status Update").
        "plan", "plans", "review", "reviews", "update", "updates", "status", "overview", "uberblick",
    ]

    // MARK: Ranking

    /// The recurring topics of the person whose transcripts are `isTheirs`: up to `maxTags` tags first, then words (a
    /// word equal to a shown tag is left out), `maxTopics` in all. `excluding`: folded words of every known person's
    /// name.
    static func topics(_ sources: [TopicSource], excluding names: Set<String>) -> [PersonTopic] {
        // Singular and plural as one key when both occur anywhere ("licence" and "licences", "lizenz" and "lizenzen").
        var keys = Set<String>()
        for source in sources { for term in source.terms { keys.insert(term.key) } }
        func merged(_ key: String) -> String {
            for ending in ["es", "en", "s", "n"] where key.hasSuffix(ending) {
                let stem = String(key.dropLast(ending.count))
                if stem.count >= 3, keys.contains(stem) { return stem }
            }
            return key
        }

        struct Tally {
            var theirs = 0, others = 0
            var spellings: [String: Int] = [:]
            var bases = Set<String>()                  // their base forms: what the word's search can look for
            var forms: [[String]] = []                 // per transcript of theirs: its spellings of the word
            var firstSeen = Int.max                    // newest first: the earliest of their transcripts, then position
        }
        func count(_ tally: inout Tally, _ source: TopicSource, terms: [Term], order: Int) {
            if source.isTheirs {
                tally.theirs += 1
                tally.spellings[terms[0].surface, default: 0] += 1
                tally.bases.formUnion(terms.map(\.base))     // "licences" in the Topics line, "Licence" in the title
                tally.forms.append(terms.map(\.surface))
                tally.firstSeen = min(tally.firstSeen, order)
            } else {
                tally.others += 1
            }
        }
        var words: [String: Tally] = [:]
        var tags: [String: Tally] = [:]
        var p = 0, o = 0
        for (index, source) in sources.enumerated() {
            // How a transcript came in is no topic: the Import tag (FED-6) would be one for anyone in two imports.
            let sourceTags = source.tags.filter {
                !importTagKeys.contains(SearchFolding.fold($0.trimmingCharacters(in: .whitespaces)))
            }
            guard !source.terms.isEmpty || !sourceTags.isEmpty else { continue }
            if source.isTheirs { p += 1 } else { o += 1 }
            var found: [(key: String, terms: [Term], position: Int)] = []   // each key once, in order
            for (position, term) in source.terms.enumerated() {
                let key = merged(term.key)
                guard !isName(key, names, source.names) else { continue }
                if let i = found.firstIndex(where: { $0.key == key }) {
                    found[i].terms.append(term)
                } else {
                    found.append((key, [term], position))
                }
            }
            for (key, terms, position) in found {
                count(&words[key, default: Tally()], source, terms: terms, order: index * 1_000 + position)
            }
            var seenTags = Set<String>()
            for (position, tag) in sourceTags.enumerated() {
                let key = SearchFolding.fold(tag.trimmingCharacters(in: .whitespaces))
                guard !key.isEmpty, seenTags.insert(key).inserted else { continue }
                count(&tags[key, default: Tally()], source, terms: [Term(key: key, surface: tag, base: tag)],
                      order: index * 1_000 + position)
            }
        }
        typealias Ranked = (key: String, topic: PersonTopic, score: Double, first: Int)
        func ranked(_ tallies: [String: Tally], _ kind: PersonTopic.Kind) -> [Ranked] {
            tallies.compactMap { key, tally -> Ranked? in
                guard tally.theirs >= minimumTranscripts, p > 0 else { return nil }
                var score = Double(tally.theirs)
                if o >= liftFromOthers {
                    let lift = (Double(tally.theirs) / Double(p)) / (Double(tally.others + 1) / Double(o + 1))
                    guard lift >= minimumLift else { return nil }
                    score *= log2(1 + lift)
                }
                let spelling = tally.spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
                // The search's text in the shown spelling's case ("licence", not the title's "Licence").
                var query = kind == .tag ? spelling : Self.query(bases: tally.bases, forms: tally.forms) ?? spelling
                if spelling.first?.isLowercase == true { query = query.lowercased() }
                return (key, PersonTopic(kind: kind, name: spelling, count: tally.theirs, query: query), score,
                        tally.firstSeen)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.first < $1.first }
        }
        let shownTags = ranked(tags, .tag).prefix(maxTags)
        let tagKeys = Set(shownTags.map(\.key))
        let shownWords = ranked(words, .word).filter { !tagKeys.contains($0.key) }
        return Array((shownTags.map(\.topic) + shownWords.map(\.topic)).prefix(maxTopics))
    }

    /// What a word chip searches (`PersonTopic.query`): the search finds a text inside words, so a form is right when it
    /// starts one of the spellings in every transcript of theirs (`forms`, one list per transcript); the shortest such
    /// base form, else the longest start of the shortest spelling that is ("Strateg" for "Strategy" and "strategies",
    /// "Firm" for "Firma" and "Firmen"). `base` and the plural merge keep that at 3 letters or more; nil if not.
    static func query(bases: Set<String>, forms: [[String]]) -> String? {
        let folded = forms.map { $0.map(SearchFolding.fold) }
        func startsEach(_ candidate: String) -> Bool {
            let start = SearchFolding.fold(candidate)
            return folded.allSatisfy { spellings in spellings.contains { $0.hasPrefix(start) } }
        }
        if let base = bases.sorted(by: { ($0.count, $0) < ($1.count, $1) }).first(where: startsEach) { return base }
        guard let shortest = forms.joined().min(by: { ($0.count, $0) < ($1.count, $1) }) else { return nil }
        for length in stride(from: shortest.count, through: 3, by: -1) {
            let start = String(shortest.prefix(length))
            if startsEach(start) { return start }
        }
        return nil
    }

    @concurrent static func topicsInBackground(_ sources: [TopicSource], excluding names: Set<String>) async -> [PersonTopic] {
        topics(sources, excluding: names)
    }

    /// Every word of `key` is a word of a name ("anna", "anna schmidt": `.joinNames` keeps a full name as one term).
    private static func isName(_ key: String, _ names: Set<String>, _ more: Set<String>) -> Bool {
        let words = key.split(separator: " ")
        return !words.isEmpty && words.allSatisfy { names.contains(String($0)) || more.contains(String($0)) }
    }

    /// The folded words of names ("Anna Schmidt" → "anna", "schmidt").
    static func nameWords(_ names: some Sequence<String>) -> Set<String> {
        var words = Set<String>()
        for name in names {
            for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) { words.insert(SearchFolding.fold(String(word))) }
        }
        return words
    }
}
