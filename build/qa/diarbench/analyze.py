import json, glob, sys, itertools
import numpy as np
OFFSET = -0.12

def load(base):
    run = json.load(open(base + '.wav.run.json')); truth = json.load(open(base + '.truth.json'))
    return run, truth

def overlap(a0, a1, b0, b1): return max(0.0, min(a1, b1) - max(a0, b0))

def align(words, turns, offset=OFFSET):
    """TranscriptAligner.finalSpeakers: largest overlap with the shifted turns, else the nearest turn midpoint."""
    ts = sorted(([t['speaker'], t['start'] + offset, t['end'] + offset] for t in turns), key=lambda t: t[1])
    out = []
    for w in words:
        best, bo = None, 0.0
        for s, a, b in ts:
            if a >= w['end']: break
            o = overlap(w['start'], w['end'], a, b)
            if o > bo: best, bo = s, o
        if best is None and ts:
            mid = (w['start'] + w['end']) / 2
            best = min(ts, key=lambda t: (abs((t[1] + t[2]) / 2 - mid), t[1]))[0]
        out.append(best)
    return out

def match(words, truth):
    """hyp word -> truth word index: largest time overlap, else the nearest within 0.3 s."""
    out = []
    for w in words:
        best, bo = None, 0.0
        for i, t in enumerate(truth):
            o = overlap(w['start'], w['end'], t['start'], t['end'])
            if o > bo: best, bo = i, o
        if best is None:
            mid = (w['start'] + w['end']) / 2
            i = min(range(len(truth)), key=lambda i: abs((truth[i]['start'] + truth[i]['end']) / 2 - mid))
            if abs((truth[i]['start'] + truth[i]['end']) / 2 - mid) < 0.3: best = i
        out.append(best)
    return out

def categories(truth):
    cat = []
    for i, t in enumerate(truth):
        same_turn = [j for j in range(len(truth)) if truth[j]['turn'] == t['turn']]
        first, last = same_turn[0], same_turn[-1]
        prev_change = i == first and first > 0 and truth[first - 1]['speaker'] != t['speaker']
        next_change = i == last and last + 1 < len(truth) and truth[last + 1]['speaker'] != t['speaker']
        over = any(u['speaker'] != t['speaker'] and overlap(t['start'], t['end'], u['start'], u['end']) > 0.02 for u in truth)
        cat.append('interjection' if t['interjection'] else 'overlap' if over else 'boundary' if (prev_change or next_change) else 'interior')
    return cat

def mapping(labels, m, truth):
    counts = {}
    for l, i in zip(labels, m):
        if l is None or i is None: continue
        counts[(l, truth[i]['speaker'])] = counts.get((l, truth[i]['speaker']), 0) + 1
    hyp = sorted({k[0] for k in counts}); ref = sorted({k[1] for k in counts})
    best, bestscore = {}, -1
    # exhaustive one-to-one (at most 4-5 speakers)
    for perm in itertools.permutations(ref, min(len(ref), len(hyp))) if len(hyp) >= len(ref) else []:
        pass
    # greedy by count (fine for these sizes), one to one
    used_h, used_r = set(), set()
    for (h, r), c in sorted(counts.items(), key=lambda kv: -kv[1]):
        if h in used_h or r in used_r: continue
        best[h] = r; used_h.add(h); used_r.add(r)
    return best

def score(labels, m, truth, cats, mp=None):
    mp = mp or mapping(labels, m, truth)
    res = {}
    for l, i in zip(labels, m):
        if i is None: continue
        c = cats[i]; ok = l is not None and mp.get(l) == truth[i]['speaker']
        res.setdefault(c, [0, 0]); res[c][0] += 1; res[c][1] += 0 if ok else 1
    return res

if __name__ == '__main__':
    bases = sorted(f[:-len('.truth.json')] for f in glob.glob('meet/*.truth.json'))
    tot = {}
    for b in bases:
        run, truth = load(b)
        lab = align(run['words'], run['turns'])
        same = sum(1 for x, y in zip(lab, run['labels']) if x == y)
        m = match(run['words'], truth); cats = categories(truth)
        r = score(lab, m, truth, cats)
        mode = b.split('_')[1]
        n = sum(v[0] for v in r.values()); e = sum(v[1] for v in r.values())
        print(f"{b[5:]:18s} python==swift {same}/{len(lab)}  WDER {100*e/n:5.2f} %  " + "  ".join(f"{k} {v[1]}/{v[0]}" for k, v in sorted(r.items())))
        for k, v in r.items():
            tot.setdefault(mode, {}).setdefault(k, [0, 0]); tot[mode][k][0] += v[0]; tot[mode][k][1] += v[1]
    for mode, r in tot.items():
        n = sum(v[0] for v in r.values()); e = sum(v[1] for v in r.values())
        print(f"{mode:8s} WDER {100*e/n:5.2f} %  errors by kind: " + ", ".join(f"{k} {v[1]} of {v[0]}" for k, v in sorted(r.items())))
