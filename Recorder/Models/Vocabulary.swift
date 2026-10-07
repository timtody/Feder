import Foundation

/// Words the speech recognizer should expect (Apple's contextual strings): the user's own words. Used by the vocabulary
/// pass after Stop (SpeechFileTranscriber), not by the live transcriber. Stored in UserDefaults; changes apply from the
/// next recording. The built-in German consulting and banking terms (`builtIn`, the "Consulting & Banking Terms" switch
/// in Settings) are off for the App Store launch (October 2026): a list for one trade doesn't fit a general app. Kept
/// for a later, optional word pack; a stored `vocabularyUseBuiltIn` is ignored meanwhile.
nonisolated enum Vocabulary {
    static let customKey = "vocabularyCustom"          // [String], the user's words in the order they were added

    /// Apple gives no hard limit for contextual strings; very long lists dilute the bias, so the total is capped.
    /// The user's own words always come first.
    static let maximumCount = 200

    static var custom: [String] {
        get { UserDefaults.standard.stringArray(forKey: customKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: customKey) }
    }

    /// What goes to the recognizer: the user's words without duplicates, capped.
    static var current: [String] {
        var seen = Set<String>()
        return custom
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maximumCount)
            .map { $0 }
    }

    /// German office, consulting, banking and finance terms the recognizer tends to miss or split.
    static let builtIn: [String] = [
        // Company and everyday office
        "Cofinpro", "Cofinpro AG", "Jour fixe", "Kick-off", "Steerco", "Lenkungsausschuss", "Stakeholder",
        "Workshop", "Deliverable", "Roadmap", "Meilenstein", "Timeline", "Personentage", "Aufwandsschätzung",
        "Angebot", "Rahmenvertrag", "Statusbericht", "Lessons Learned", "Quick Win", "Teams-Call", "Outlook",
        "SharePoint", "Confluence", "Jira", "PowerPoint", "Excel",
        // Projects and methods
        "Scrum", "Sprint", "Backlog", "Product Owner", "Retro", "Use Case", "Business Case", "Proof of Concept",
        "MVP", "Go-live", "Rollout", "Fachkonzept", "Lastenheft", "Pflichtenheft", "Ist-Analyse", "Soll-Konzept",
        "Zielbild", "Anforderungsmanagement", "Testmanagement", "Abnahme", "Change Request", "PMO",
        "Projektleitung", "Datenmigration", "Schnittstelle", "API", "Cloud", "Prozessoptimierung",
        "Automatisierung", "Digitalisierung", "Künstliche Intelligenz",
        // Banking and lending
        "Kreditprozess", "Kreditantrag", "Kreditentscheidung", "Kreditwürdigkeit", "Bonität", "Scoring",
        "Baufinanzierung", "Immobilienfinanzierung", "Konsumentenkredit", "Firmenkunden", "Privatkunden",
        "Kernbankensystem", "Zahlungsverkehr", "SEPA", "Instant Payments", "Onboarding", "Sparkasse",
        "Volksbank", "Genossenschaftsbank", "Landesbank", "Förderbank", "Direktbank", "Kapitalverwaltungsgesellschaft",
        "Asset Management", "Wertpapiere", "Depot", "Fondsgesellschaft",
        // Regulation and risk
        "Regulatorik", "Meldewesen", "BaFin", "EZB", "Bundesbank", "MaRisk", "BAIT", "DORA", "CRR", "CRD",
        "Basel IV", "IFRS 9", "KWG", "DSGVO", "Geldwäsche", "KYC", "AML", "ESG", "EU-Taxonomie",
        "Risikomanagement", "Kreditrisiko", "Marktrisiko", "Liquiditätsrisiko", "Eigenkapital", "RWA",
        "Stresstest", "Revision", "Compliance",
    ]
}
