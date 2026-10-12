import json, glob
import numpy as np
from analyze import load, align, match, categories, score, mapping, OFFSET

bases = sorted(f[:-len('.truth.json')] for f in glob.glob('meet/*.truth.json'))
data = []
for b in bases:
    run, truth = load(b)
    data.append(dict(base=b, mode=b.split('_')[1], run=run, truth=truth, m=match(run['words'], truth), cats=categories(truth),
                     E=np.array(run['embeddings'], dtype=np.float32)))

def unit(v): n = np.linalg.norm(v); return v / n if n > 0 else v

def centroids(labels, E):
    """per label: mean embedding of words at least 2 words inside runs of >= 5 words with that label"""
    runs, start = [], 0
    for i in range(1, len(labels) + 1):
        if i == len(labels) or labels[i] != labels[start]: runs.append((start, i)); start = i
    acc = {}
    for a, b in runs:
        if b - a < 5 or labels[a] is None: continue
        for i in range(a + 2, b - 2): acc.setdefault(labels[a], []).append(E[i])
    return {l: unit(np.mean(v, axis=0)) for l, v in acc.items()}

# ---- A: boundary snapping
def snap(words, turns, window):
    ts = sorted([dict(t) for t in turns], key=lambda t: t['start'])
    gaps = [((words[i]['end'] + words[i + 1]['start']) / 2, words[i + 1]['start'] - words[i]['end']) for i in range(len(words) - 1)]
    gaps = [(g - OFFSET, w) for g, w in gaps]            # into the turns' time (turns are shifted by OFFSET when aligned)
    for k in range(len(ts) - 1):
        a, b = ts[k], ts[k + 1]
        if a['speaker'] == b['speaker'] or b['start'] - a['end'] > 1.0: continue
        centre = (a['end'] + b['start']) / 2
        near = [g for g, w in gaps if abs(g - centre) <= window and w > 0.0]
        if not near: continue
        g = min(near, key=lambda g: abs(g - centre))
        a['end'] = min(a['end'], g) if b['start'] >= a['end'] else g
        a['end'] = g; b['start'] = g
    return ts

# ---- B: voice check of the words at a label change
def voice_boundary(labels, E, k, margin):
    C = centroids(labels, E); out = list(labels)
    for i in range(1, len(labels)):
        L, R = labels[i - 1], labels[i]
        if L == R or L is None or R is None or L not in C or R not in C: continue
        for j in range(max(0, i - k), min(len(labels), i + k)):
            own = labels[j]; other = R if j < i else L
            if np.dot(E[j], C[other]) - np.dot(E[j], C[own]) > margin: out[j] = other
    return out

# ---- C: voice check of short runs between pauses
def voice_short(labels, E, words, maxlen, gap, margin):
    C = centroids(labels, E); out = list(labels)
    n = len(words)
    for i in range(n):
        for length in range(1, maxlen + 1):
            j = i + length
            if j > n: break
            before = words[i]['start'] - words[i - 1]['end'] if i > 0 else 9
            after = words[j]['start'] - words[j - 1]['end'] if j < n else 9
            if before < gap or after < gap: continue
            if len({labels[x] for x in range(i, j)}) != 1: continue
            own = labels[i]
            if own is None or own not in C: continue
            e = unit(E[i:j].mean(axis=0))
            best = max(C, key=lambda l: np.dot(e, C[l]))
            if best != own and np.dot(e, C[best]) - np.dot(e, C[own]) > margin:
                for x in range(i, j): out[x] = best
    return out

def evaluate(name, fn):
    tot = {}
    fixed = broken = 0
    for d in data:
        base = align(d['run']['words'], d['run']['turns'])
        lab = fn(d, base)
        mp = mapping(base, d['m'], d['truth'])                  # the same speaker mapping as the baseline
        for l0, l1, i in zip(base, lab, d['m']):
            if i is None or l0 == l1: continue
            ok0 = mp.get(l0) == d['truth'][i]['speaker']; ok1 = mp.get(l1) == d['truth'][i]['speaker']
            fixed += (not ok0) and ok1; broken += ok0 and not ok1
        r = score(lab, d['m'], d['truth'], d['cats'], mp)
        for k, v in r.items():
            tot.setdefault(d['mode'], {}).setdefault(k, [0, 0]); tot[d['mode']][k][0] += v[0]; tot[d['mode']][k][1] += v[1]
    line = []
    allw = alle = 0
    for mode in ('normal', 'fast', 'overlap'):
        r = tot[mode]; n = sum(v[0] for v in r.values()); e = sum(v[1] for v in r.values()); allw += n; alle += e
        line.append(f"{mode} {100*e/n:4.2f}")
    print(f"{name:44s} all {100*alle/allw:4.2f} %  " + "  ".join(line) + f"   fixed {fixed:3d} broken {broken:3d}")

evaluate('baseline', lambda d, base: base)
for w in (0.2, 0.3, 0.45, 0.6):
    evaluate(f'A snap boundaries to pauses (±{w} s)', lambda d, base, w=w: align(d['run']['words'], snap(d['run']['words'], d['run']['turns'], w)))
for k in (1, 2):
    for m in (0.0, 0.05, 0.1, 0.2):
        evaluate(f'B voice at changes (k={k}, margin {m})', lambda d, base, k=k, m=m: voice_boundary(base, d['E'], k, m))
for L in (1, 2):
    for g in (0.1, 0.2):
        for m in (0.05, 0.15, 0.3):
            evaluate(f'C voice of short runs (≤{L} w, pause {g}, margin {m})', lambda d, base, L=L, g=g, m=m: voice_short(base, d['E'], d['run']['words'], L, g, m))
