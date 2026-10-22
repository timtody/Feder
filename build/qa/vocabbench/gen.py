"""Clips and manifests for the vocabulary bench (README › After Stop: words, speakers, vocabulary; FED-56).

  python3 gen.py synth          clips/synth/<voice>/*.wav + clips/synth.json: the sentences below, read by `say`
  python3 gen.py mls <utt dir>  clips/mls.json: real German read speech (Multilingual LibriSpeech, DiarBench's utt/
                                and its reference transcripts in utt/manifest.json)

Sentence kinds: "term" (vocabulary terms from Vocabulary.builtIn in a natural sentence), "name" (people's names, not
in the vocabulary today: the before-number for FED-55), "control" (sentences that must stay as they are: 23 with a
near-miss word such as "kaufen, pro", "Marisa", "Dora", "malte", and 5 plain ones). The expected terms are not listed here: the bench counts every vocabulary
term in each sentence's text, so the reference is the text itself.
"""
import glob, json, os, subprocess, sys

TERMS = [
    "Ich arbeite seit drei Jahren bei der Cofinpro in Frankfurt.",
    "Die Cofinpro AG hat uns gestern eine neue Version geschickt.",
    "Die BaFin hat die Prüfung für nächsten Monat angekündigt.",
    "Wir müssen den Bericht bis Freitag an die BaFin schicken.",
    "Laut MaRisk brauchen wir dafür eine eigene Risikoanalyse.",
    "Die Anforderungen der MaRisk gelten auch für kleine Institute.",
    "Die BAIT regeln die Sicherheit der Informationstechnik in den Banken.",
    "Bei der Prüfung ging es vor allem um die BAIT.",
    "Mit DORA kommen neue Meldepflichten für Vorfälle.",
    "Bis Januar müssen alle Verträge den Anforderungen von DORA genügen.",
    "Das Thema bringen wir am Donnerstag in die Steerco.",
    "Die Steerco hat das Budget für das zweite Quartal freigegeben.",
    "Lass uns das im nächsten Jour fixe besprechen.",
    "Der Jour fixe mit dem Kunden fällt diese Woche aus.",
    "Der Kick-off für das neue Projekt ist am Montag um zehn.",
    "Nach dem Kick-off haben wir die Rollen verteilt.",
    "Die Sparkasse möchte ihre Kreditanträge digitalisieren.",
    "Unser Ansprechpartner bei der Sparkasse ist im Urlaub.",
    "Die Volksbank hat drei neue Filialen eröffnet.",
    "Wir haben mit der Volksbank über die neue Anbindung gesprochen.",
    "Ab Oktober gelten für SEPA neue Fristen.",
    "Die Überweisungen laufen komplett über SEPA.",
    "Die Prüfung nach KYC dauert bei großen Kunden oft Wochen.",
    "Ohne KYC dürfen wir kein Konto eröffnen.",
    "Nach IFRS 9 müssen wir die Risikovorsorge neu berechnen.",
    "Das Modell für IFRS 9 ist noch nicht freigegeben.",
    "Mit Basel IV steigen die Anforderungen an die Banken.",
    "Die Umsetzung von Basel IV beginnt im nächsten Jahr.",
    "Der Product Owner priorisiert die Aufgaben jede Woche.",
    "Frag am besten den Product Owner, der weiß das.",
    "Das ist kein Fehler, das ist ein Change Request.",
    "Den Change Request schätzen wir auf zwanzig Tage.",
    "Das Lastenheft ist noch nicht vollständig.",
    "Im Lastenheft steht davon nichts.",
    "Wir schreiben bis Ende des Monats das Pflichtenheft.",
    "Das Pflichtenheft muss der Kunde noch unterschreiben.",
    "Das Kernbankensystem wird im Sommer umgestellt.",
    "Die Daten kommen direkt aus dem Kernbankensystem.",
    "Im Meldewesen fehlen uns noch zwei Leute.",
    "Das Meldewesen braucht die Zahlen bis zum Fünften.",
    "Die Regulatorik ändert sich fast jedes Jahr.",
    "Für die Regulatorik haben wir ein eigenes Team.",
    "Die Bonität des Kunden wird automatisch geprüft.",
    "Bei schlechter Bonität lehnen wir den Antrag ab.",
    "Die Protokolle liegen alle in Confluence.",
    "Kannst du das bitte in Confluence aufschreiben?",
    "Leg dafür bitte ein Ticket in Jira an.",
    "In Jira sind noch vierzig offene Tickets.",
    "Die Präsentation liegt auf dem SharePoint.",
    "Ich habe dir den Link zum SharePoint geschickt.",
    "Der Go-live ist für den ersten März geplant.",
    "Nach dem Go-live gibt es zwei Wochen Betreuung.",
    "Wir starten erst einmal mit einem Proof of Concept.",
    "Der Proof of Concept hat gezeigt, dass es funktioniert.",
    "Die EZB hat den Leitzins wieder gesenkt.",
    "Die Vorgaben der EZB kommen im Herbst.",
    "Nach dem KWG ist das eine meldepflichtige Auslagerung.",
    "Paragraf fünfundzwanzig KWG regelt die Auslagerung.",
    "Das ist nach der DSGVO nicht erlaubt.",
    "Die DSGVO verlangt hier eine Einwilligung.",
    "Die RWA steigen durch das neue Modell deutlich.",
    "Wir müssen die RWA bis zum Quartalsende senken.",
    "Die Aufwandsschätzung schicke ich dir morgen.",
    "Ohne Aufwandsschätzung können wir nichts zusagen.",
    "Der Lenkungsausschuss tagt einmal im Monat.",
    "Das muss der Lenkungsausschuss entscheiden.",
    "Die Nachfrage nach Baufinanzierung ist stark gesunken.",
    "Für die Baufinanzierung brauchen wir noch Ihre Gehaltsnachweise.",
]

# People's names (FED-55 would add them to the contextual strings; the bench passes them with --names).
NAMES = ["Malte Kühnert", "Svenja Oberreiter", "Ilkay Demirci", "Tjark Ohlsen"]
NAME_SENTENCES = [
    "Malte Kühnert übernimmt ab Montag die Leitung.",
    "Ich habe gestern mit Malte Kühnert telefoniert.",
    "Svenja Oberreiter stellt die Ergebnisse morgen vor.",
    "Die Freigabe kommt von Svenja Oberreiter.",
    "Ilkay Demirci kümmert sich um die Umstellung.",
    "Frag doch mal Ilkay Demirci, ob er Zeit hat.",
    "Tjark Ohlsen ist diese Woche beim Kunden.",
    "Die Zahlen hat Tjark Ohlsen schon geprüft.",
]

# Controls: none of these may end up with a vocabulary term (or, with --names, a name) in it. Each is (sentence, near
# miss, lure): the near miss is the word or words that sound or look like the lure, a vocabulary term; the plain
# sentences (no near miss) only check that the dictation pass invents no term. The dictation pass has so far written no
# term on any control, so the merge's matching never runs on them by itself: the bench's lure test puts the lure into
# the hinted words over the near miss (as if the dictation pass had misheard it) and counts how often the merge takes
# it over. That is the gate FED-54 loosens.
CONTROLS = [
    ("Wir wollen das Gerät kaufen, pro Stück kostet es zehn Euro.", "kaufen, pro", "Cofinpro"),
    ("Eine Tasse Koffein pro Tag reicht mir völlig.", "Koffein pro", "Cofinpro"),
    ("Marisa kommt heute etwas später ins Büro.", "Marisa", "MaRisk"),
    ("Maria riskiert bei dem Projekt sehr viel.", "Maria riskiert", "MaRisk"),
    ("Marius hat das Risiko gut erklärt.", "Marius", "MaRisk"),
    ("Mein Bruder bekommt noch Bafög vom Staat.", "Bafög", "BaFin"),
    ("Die Bahn fing plötzlich an zu bremsen.", "Bahn fing", "BaFin"),
    ("Meine Tante Dora kommt am Wochenende zu Besuch.", "Dora", "DORA"),
    ("Dora hat die Kinder von der Schule abgeholt.", "Dora", "DORA"),
    ("Im Auto läuft das Stereo viel zu laut.", "Stereo", "Steerco"),
    ("Kira hat die Präsentation gestern fertig gemacht.", "Kira", "Jira"),
    ("Die Farbe Sepia wirkt auf alten Fotos warm.", "Sepia", "SEPA"),
    ("Am Wochenende waren wir auf dem Volksfest.", "Volksfest", "Volksbank"),
    ("Ich spare jeden Monat etwas in die Haushaltskasse.", "Haushaltskasse", "Sparkasse"),
    ("Das Lastenrad steht vor der Tür.", "Lastenrad", "Lastenheft"),
    ("In Basel waren wir vier Tage im Urlaub.", "Basel", "Basel IV"),
    ("Er malte ein Bild von seinem Hund.", "malte", "Malte Kühnert"),
    ("Sven, ja, das machen wir so.", "Sven, ja", "Svenja Oberreiter"),
    ("Die Kinder spielen draußen im Garten.", None, None),
    ("Wir treffen uns um vier Uhr am Bahnhof.", None, None),
    ("Das Wetter wird morgen deutlich besser.", None, None),
    ("Das Kabel ist kaputt, kauf bitte ein neues.", "kaputt, kauf", "Cofinpro"),
    ("Ich habe das Formular im Büro vergessen.", None, None),
    ("Die Gäste kommen gegen acht.", None, None),
    ("Die Kunden kaufen am liebsten im Laden um die Ecke.", "kaufen", "Cofinpro"),
    ("Der Bonbon klebt am Papier.", "Bonbon", "Bonität"),
    ("Wir sind über die Brücke nach Oberursel gefahren.", "Oberursel", "Svenja Oberreiter"),
    ("Die Ehe der beiden hält schon dreißig Jahre.", "Ehe", "EZB"),
]

# Anna is the only German voice on this Mac that is not a formant synthesizer; Reed (Eloquence) is the second voice,
# reported separately. Each is the de_DE voice of that name: a bare `say -v Reed` picks the British English Reed (12
# locales have one), which reads the German sentences as English.
VOICES = ["Anna", "Reed"]

# A short list such as a user's own vocabulary (Vocabulary.current sends only the user's words; the built-in list is
# off): the 35 terms the sentences above use. `run.sh --short` sends it instead of Vocabulary.builtIn.
SHORT = ["Cofinpro", "Cofinpro AG", "Jour fixe", "Kick-off", "Steerco", "Lenkungsausschuss", "Aufwandsschätzung",
         "SharePoint", "Confluence", "Jira", "Product Owner", "Proof of Concept", "Go-live", "Lastenheft",
         "Pflichtenheft", "Change Request", "Bonität", "Baufinanzierung", "Kernbankensystem", "SEPA", "Sparkasse",
         "Volksbank", "Regulatorik", "Meldewesen", "BaFin", "EZB", "MaRisk", "BAIT", "DORA", "Basel IV", "IFRS 9",
         "KWG", "DSGVO", "KYC", "RWA"]

here = os.path.dirname(os.path.abspath(__file__))


def german_voice(name):
    """The full name `say` knows the de_DE voice `name` by ("Reed (Deutsch (Deutschland))"; localized)."""
    for line in subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout.splitlines():
        full, _, rest = line.partition("#")[0].rstrip().rpartition(" ")
        full = full.strip()
        if rest == "de_DE" and (full == name or full.startswith(name + " (")):
            return full
    sys.exit(f"no de_DE voice {name} on this Mac (say -v '?')")


def say(voice, text, path):
    # `say` with an Eloquence voice hung once for 15 minutes on one sentence (a rerun took a second), and a killed
    # run leaves a 4 KB header: write to a temporary name, with a timeout and retries.
    for _ in range(3):
        try:
            subprocess.run(["say", "-v", voice, "-o", path + ".tmp.wav", "--file-format=WAVE",
                            "--data-format=LEI16@16000", text], check=True, timeout=60)
            os.rename(path + ".tmp.wav", path)
            return
        except subprocess.TimeoutExpired:
            pass
    sys.exit(f"say -v {voice} timed out three times: {text}")


def synth():
    clips = []
    for voice in VOICES:
        full = german_voice(voice)
        folder = os.path.join(here, "clips", "synth", voice)
        os.makedirs(folder, exist_ok=True)
        for kind, prefix, sentences in (("term", "t", TERMS), ("name", "n", NAME_SENTENCES), ("control", "c", CONTROLS)):
            for i, entry in enumerate(sentences):
                text, near, lure = entry if kind == "control" else (entry, None, None)
                cid = f"{voice}-{prefix}{i:02d}"
                path = os.path.join(folder, f"{prefix}{i:02d}.wav")
                # The file name comes from the sentence's place in its list, so an edited or inserted sentence would
                # keep the old audio under the new text: each clip keeps what it was read from (voice and sentence)
                # next to it, and a clip whose record differs or is missing is read again. Only when the audio really
                # changed are the recognizer passes cached for its id (out/base*/, out/hinted-*/) dropped: `say` is
                # deterministic (all 208 clips regenerated byte-identical), so a missing record alone costs no re-run.
                record, read_from = path[:-4] + ".txt", f"{full}\t{text}\n"
                if not os.path.exists(record) or open(record, encoding="utf-8").read() != read_from:
                    new = path[:-4] + ".new.wav"
                    say(full, text, new)
                    old = open(path, "rb").read() if os.path.exists(path) else None
                    if old == open(new, "rb").read():
                        os.remove(new)
                    else:
                        os.replace(new, path)
                        for cached in glob.glob(os.path.join(here, "out", "*", cid + ".json")):
                            os.remove(cached)
                    with open(record, "w", encoding="utf-8") as f:
                        f.write(read_from)
                clip = {"id": cid, "wav": path, "text": text, "kind": kind, "voice": voice}
                if near:
                    clip["near"], clip["lure"] = near, lure
                clips.append(clip)
    with open(os.path.join(here, "clips", "synth.json"), "w") as f:
        json.dump({"names": NAMES, "short": SHORT, "clips": clips}, f, ensure_ascii=False, indent=1)
    print(f"{len(clips)} synthetic clips -> clips/synth.json")


def mls(utt):
    # The reference is MLS's own transcript (utt/manifest.json: lowercase, no punctuation, numbers as words), not the
    # <wav>.words.json next to each clip: those are DiarBench's Parakeet words, a recognizer's output.
    clips = []
    for m in json.load(open(os.path.join(utt, "manifest.json"))):
        clips.append({"id": m["id"], "wav": os.path.abspath(os.path.join(utt, m["id"] + ".wav")),
                      "text": m["transcript"], "kind": "real", "voice": "MLS"})
    os.makedirs(os.path.join(here, "clips"), exist_ok=True)
    with open(os.path.join(here, "clips", "mls.json"), "w") as f:
        json.dump({"names": NAMES, "short": SHORT, "clips": clips}, f, ensure_ascii=False, indent=1)
    print(f"{len(clips)} real clips -> clips/mls.json")


if __name__ == "__main__":
    if sys.argv[1:2] == ["synth"]:
        synth()
    elif sys.argv[1:2] == ["mls"] and len(sys.argv) == 3:
        mls(sys.argv[2])
    else:
        sys.exit(__doc__)
