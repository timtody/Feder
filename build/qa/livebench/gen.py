import json, random, subprocess, wave, os, sys
pool = [
 "Guten Morgen zusammen, lasst uns mit dem Status beginnen.",
 "Ja, gerne.", "Genau.", "Okay.", "Das sehe ich auch so.", "Moment, eine Frage dazu.",
 "Der Kreditprozess ist bei der Sparkasse fast fertig, wir brauchen nur noch die Abnahme.",
 "Die Schnittstelle zum Kernbankensystem läuft seit gestern stabil.",
 "Wann ist der Termin mit dem Lenkungsausschuss?",
 "Ich glaube am Donnerstag um zehn Uhr, ich schicke euch die Einladung.",
 "Wir sollten die Testfälle noch einmal durchgehen, bevor wir live gehen.",
 "Das Budget für die Workshops ist leider überschritten.",
 "Können wir einen Teil vom Lizenzbudget umschichten?",
 "Das müssen wir mit dem Finanzbereich abstimmen.",
 "Ich kümmere mich darum und melde mich bis Freitag.",
 "Hast du die Präsentation für morgen schon fertig?",
 "Fast, mir fehlen noch zwei Folien zur Datenmigration.",
 "Die Migration der Altdaten dauert länger als geplant, weil die Qualität schlechter ist als erwartet.",
 "Dann brauchen wir mehr Personentage im Angebot.",
 "Lass uns das im nächsten Jour fixe besprechen.",
 "Super, danke dir.", "Alles klar, bis später.",
 "Was sagt die Revision zu den neuen Anforderungen aus der Regulatorik?",
 "Die Revision möchte eine vollständige Dokumentation der Änderungen, insbesondere für das Meldewesen.",
 "Hm, das wird knapp.",
]
voices = {0: "Anna", 1: "Reed"}
def say(text, voice, path):
    subprocess.run(["say", "-v", voice, "-o", path, "--file-format=WAVE", "--data-format=LEI16@16000", text], check=True)
for conv in range(int(sys.argv[1]) if len(sys.argv) > 1 else 3):
    rng = random.Random(100 + conv)
    frames = []; t = 0.6; truth = []; speaker = 0; script = []
    def silence(sec): return b"\x00\x00" * int(16000 * sec)
    frames.append(silence(0.6))
    while t < 120:
        n = rng.choice([1, 1, 2, 2, 3])                    # sentences in this turn
        start = t
        for i in range(n):
            text = rng.choice(pool)
            p = f"audio/tmp.wav"; say(text, voices[speaker], p)
            with wave.open(p) as w: data = w.readframes(w.getnframes())
            # trim leading/trailing digital silence
            import array
            a = array.array("h", data); lo = 0; hi = len(a)
            while lo < hi and abs(a[lo]) < 60: lo += 1
            while hi > lo and abs(a[hi - 1]) < 60: hi -= 1
            seg = a[lo:hi].tobytes(); dur = (hi - lo) / 16000
            frames.append(seg); script.append((speaker, text, t, t + dur)); t += dur
            if i < n - 1:
                gap = rng.uniform(0.3, 0.7) if rng.random() < 0.8 else rng.uniform(1.2, 2.4)   # a pause inside the turn
                frames.append(silence(gap)); t += gap
        truth.append({"speaker": speaker, "start": start, "end": t})
        gap = rng.uniform(0.15, 0.8) if rng.random() < 0.75 else rng.uniform(1.0, 2.5)
        frames.append(silence(gap)); t += gap
        if rng.random() < 0.8: speaker = 1 - speaker
    with wave.open(f"audio/conv{conv}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b"".join(frames))
    json.dump({"turns": truth, "sentences": [{"speaker": s, "text": x, "start": a, "end": b} for s, x, a, b in script]}, open(f"audio/conv{conv}.json", "w"), indent=1)
    print(conv, round(t, 1), "s", len(truth), "turns")
os.remove("audio/tmp.wav")
