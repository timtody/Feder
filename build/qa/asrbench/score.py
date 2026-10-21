"""Scores bench.py's runs (FED-198) the way nemotronlive and vocabbench do, so the numbers sit beside FED-196's.

  python3 score.py [run…]        default: every out/*.json

MLS: word errors with letters and digits only, case folded (nemotronlive's `normalized`); the cached Apple and
Parakeet passes of vocabbench are scored alongside as a check (FED-196: 7.4 % and 5.3 %). Made-up text: words the
hypothesis has beyond the reference's (insertions), clips whose hypothesis is 20 % longer, and runs of a repeated
word or 3-gram. Synth: term accuracy as vocabbench counts it (exact spelling, case and spaces matter, punctuation
around a word doesn't; a term inside a longer one isn't counted again), per voice, plus WER per voice and kind.
"""
import json, sys, unicodedata
from pathlib import Path
from bench import VOCAB

HERE = Path(__file__).resolve().parent


def normalized(text):
    words = []
    for w in text.lower().split():
        w = "".join(c for c in w if unicodedata.category(c)[0] in "LMN")
        if w:
            words.append(w)
    return words


def alignment(ref, hyp):
    """(substitutions, deletions, insertions) of a minimal edit."""
    n, m = len(ref), len(hyp)
    d = [[(0, 0, 0, 0)] * (m + 1) for _ in range(n + 1)]       # (cost, s, d, i)
    for i in range(1, n + 1): d[i][0] = (i, 0, i, 0)
    for j in range(1, m + 1): d[0][j] = (j, 0, 0, j)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            c, s, dd, ii = d[i - 1][j - 1]
            best = (c, s, dd, ii) if ref[i - 1] == hyp[j - 1] else (c + 1, s + 1, dd, ii)
            c, s, dd, ii = d[i - 1][j]
            best = min(best, (c + 1, s, dd + 1, ii))
            c, s, dd, ii = d[i][j - 1]
            best = min(best, (c + 1, s, dd, ii + 1))
            d[i][j] = best
    return d[n][m][1:]


def repeats(words):
    """Longest run of one word or 3-gram repeated back to back (models that loop show 4+)."""
    best = 1
    for size in (1, 3):
        for start in range(len(words)):
            run, k = 1, start + size
            while k + size <= len(words) and words[k:k + size] == words[start:start + size]:
                run += 1; k += size
            best = max(best, run)
    return best


def wer_stats(pairs):
    s = dl = ins = total = longer = 0
    loops = []
    for cid, ref, hyp in pairs:
        r, h = normalized(ref), normalized(hyp)
        a, b, c = alignment(r, h)
        s += a; dl += b; ins += c; total += len(r)
        if len(h) > 1.2 * len(r) + 2: longer += 1
        if repeats(h) >= 4 and repeats(h) > repeats(r): loops.append(cid)
    return {"wer": (s + dl + ins) / max(1, total) * 100, "sub": s, "del": dl, "ins": ins, "words": total,
            "longer": longer, "loops": loops}


def edge_stripped(text):
    out = []
    for w in text.split():
        w = w.strip(".,;:!?\"'()[]„“”‚‘’«»…")
        if w: out.append(w)
    return out


def term_counts(text, terms):
    words = edge_stripped(text)
    used = [False] * len(words)
    counts = {}
    for term in sorted(terms, key=lambda t: -len(t.split())):
        tw = term.split(); n = 0
        for i in range(len(words) - len(tw) + 1):
            if words[i:i + len(tw)] == tw and not any(used[i:i + len(tw)]):
                n += 1
                for k in range(i, i + len(tw)): used[k] = True
        if n: counts[term] = n
    return counts


def term_stats(clips, terms):
    by = {}
    for c in clips:
        if c["kind"] != "term":
            # A term written into a sentence without one (controls hold near misses: "Bahn" for BaFin).
            g = by.setdefault(c["voice"], [0, 0, 0, 0])
            g[3] += sum(n for t, n in term_counts(c["hyp"], terms).items() if t not in term_counts(c["ref"], terms))
            continue
        ref, hyp = term_counts(c["ref"], terms), term_counts(c["hyp"], terms)
        g = by.setdefault(c["voice"], [0, 0, 0, 0])
        g[0] += sum(ref.values())
        g[1] += sum(min(n, hyp.get(t, 0)) for t, n in ref.items())
        g[2] += sum(max(0, n - ref.get(t, 0)) for t, n in hyp.items())
    return by


def cached(folder, clips):
    """vocabbench's cached pass for these clips, as (id, ref, hyp)."""
    out = []
    for c in clips:
        f = VOCAB / "out" / folder / f"{c['id']}.json"
        if not f.exists(): return None
        out.append((c["id"], c["text"], " ".join(w["text"] for w in json.load(open(f))["words"])))
    return out


def main():
    runs = sys.argv[1:] or sorted(p.stem for p in (HERE / "out").glob("*.json"))
    results = [json.load(open(HERE / "out" / f"{r}.json")) for r in runs]
    mls = json.load(open(VOCAB / "clips" / "mls.json"))["clips"]
    synth = json.load(open(VOCAB / "clips" / "synth.json"))
    terms = synth["short"]

    print("MLS, 192 real German clips: word errors (letters and digits, case folded)")
    print(f"{'run':28} {'WER':>6} {'sub':>5} {'del':>5} {'ins':>5}  {'longer':>6} {'loops':>5}  {'speed':>8}")
    for name, folder in (("Apple offline (cached)", "base"), ("Parakeet Ultra (cached)", "base-parakeet")):
        pairs = cached(folder, mls)
        if pairs:
            w = wer_stats(pairs)
            print(f"{name:28} {w['wer']:5.1f}% {w['sub']:5} {w['del']:5} {w['ins']:5}  {w['longer']:6} {len(w['loops']):5}")
    for r in results:
        if r["set"] != "mls": continue
        w = wer_stats([(c["id"], c["ref"], c["hyp"]) for c in r["clips"]])
        print(f"{r['run']:28} {w['wer']:5.1f}% {w['sub']:5} {w['del']:5} {w['ins']:5}  {w['longer']:6} "
              f"{len(w['loops']):5}  {r['audio_s'] / r['wall_s']:6.1f}x" + (f"  loops: {w['loops'][:4]}" if w["loops"] else ""))

    synth_runs = [r for r in results if r["set"] == "synth"]
    if synth_runs:
        print(f"\nSynth, 208 sentences (two Eloquence voices): terms right / in the references (false: extra terms)")
        rows = [("Parakeet Ultra (cached)", [{**c, "ref": c["text"], "hyp": h} for c, (_, _, h) in
                 zip(synth["clips"], cached("base-parakeet", synth["clips"]) or [])])]
        rows += [(r["run"] + (" +hotwords" if r.get("hotwords") else ""), r["clips"]) for r in synth_runs]
        for name, clips in rows:
            if not clips: continue
            by = term_stats(clips, terms)
            cols = "  ".join(f"{v}: {g[1]}/{g[0]} ({g[1] / g[0] * 100:.0f} %), false {g[2]}, in controls {g[3]}" for v, g in sorted(by.items()))
            wers = "  ".join(f"{v} {k} {wer_stats([(c['id'], c['ref'], c['hyp']) for c in clips if c['voice'] == v and c['kind'] == k])['wer']:.1f}%"
                             for v in ("Anna", "Reed") for k in ("term", "control"))
            print(f"{name:36} {cols}\n{'':36} WER {wers}")


if __name__ == "__main__":
    main()
