import numpy as np
from variants import data, align, centroids, mapping
# For every word: is the nearest speaker voice (centroids from the baseline labels) the word's TRUE speaker?
res = {}
for d in data:
    words, truth, m, E = d['run']['words'], d['truth'], d['m'], d['E']
    base = align(words, d['run']['turns']); mp = mapping(base, m, truth); C = centroids(base, E)
    inv = {r: h for h, r in mp.items()}
    for i, w in enumerate(words):
        if m[i] is None: continue
        t = truth[m[i]]; c = d['cats'][m[i]]
        true_label = inv.get(t['speaker'])
        if true_label not in C: continue
        nearest = max(C, key=lambda l: float(np.dot(E[i], C[l])))
        dur = w['end'] - w['start']
        key = (c, 'short <0.3 s' if dur < 0.3 else 'long ≥0.3 s')
        res.setdefault(key, [0, 0]); res[key][0] += 1; res[key][1] += nearest == true_label
        res.setdefault(('baseline aligner', c), [0, 0]); res[('baseline aligner', c)][0] += 1
        res[('baseline aligner', c)][1] += mp.get(base[i]) == t['speaker']
for k in sorted(res): print(f"{str(k):45s} {100*res[k][1]/res[k][0]:5.1f} % right of {res[k][0]}")
