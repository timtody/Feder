import numpy as np
from variants import data, align, centroids, mapping
changed = fixed = broken = cand = 0; base_wrong = voice_wrong = 0
for d in data:
    words, truth, m, E = d['run']['words'], d['truth'], d['m'], d['E']
    base = align(words, d['run']['turns']); mp = mapping(base, m, truth); C = centroids(base, E)
    for i, w in enumerate(words):
        if m[i] is None or d['cats'][m[i]] != 'overlap' or w['end'] - w['start'] < 0.3: continue
        cand += 1
        v = max(C, key=lambda l: float(np.dot(E[i], C[l])))
        ok0 = mp.get(base[i]) == truth[m[i]]['speaker']; ok1 = mp.get(v) == truth[m[i]]['speaker']
        base_wrong += not ok0; voice_wrong += not ok1
        if v != base[i]: changed += 1; fixed += (not ok0) and ok1; broken += ok0 and not ok1
print("long words in overlap:", cand, " aligner wrong:", base_wrong, " voice wrong:", voice_wrong, " changed:", changed, " fixed:", fixed, " broken:", broken)
