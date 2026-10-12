import numpy as np
from variants import data, align, centroids, mapping
# Upper bound: in KNOWN overlap (from the truth), words of >= 0.3 s take the nearest voice; everything else as today.
tot = {}
for d in data:
    words, truth, m, E = d['run']['words'], d['truth'], d['m'], d['E']
    base = align(words, d['run']['turns']); mp = mapping(base, m, truth); C = centroids(base, E)
    for i, w in enumerate(words):
        if m[i] is None: continue
        t = truth[m[i]]
        lab = base[i]
        if d['cats'][m[i]] == 'overlap' and w['end'] - w['start'] >= 0.3 and C:
            lab = max(C, key=lambda l: float(np.dot(E[i], C[l])))
        for key, l in (('today', base[i]), ('voice in known overlap', lab)):
            tot.setdefault((d['mode'], key), [0, 0]); tot[(d['mode'], key)][0] += 1; tot[(d['mode'], key)][1] += mp.get(l) != t['speaker']
for mode in ('normal', 'fast', 'overlap'):
    a, b = tot[(mode, 'today')], tot[(mode, 'voice in known overlap')]
    print(f"{mode:8s} today {100*a[1]/a[0]:4.2f} %  ->  with voice in known overlap {100*b[1]/b[0]:4.2f} %")
a = [sum(tot[(m, 'today')][k] for m in ('normal', 'fast', 'overlap')) for k in (0, 1)]
b = [sum(tot[(m, 'voice in known overlap')][k] for m in ('normal', 'fast', 'overlap')) for k in (0, 1)]
print(f"all      today {100*a[1]/a[0]:4.2f} %  ->  {100*b[1]/b[0]:4.2f} %")
