import numpy as np
from variants import data, evaluate, align, OFFSET, centroids, unit
import variants

# ---- How far are the diarizer's wrong boundaries from the true ones, and how wide is the true pause?
dist, widths, within = [], [], []
for d in data:
    words, truth, m = d['run']['words'], d['truth'], d['m']
    base = align(words, d['run']['turns'])
    mp = variants.mapping(base, m, truth)
    for i in range(1, len(words)):
        if m[i] is None or m[i - 1] is None: continue
        if truth[m[i]]['speaker'] != truth[m[i - 1]]['speaker']:          # a true change between hyp words i-1 | i
            gap = words[i]['start'] - words[i - 1]['end']
            widths.append(gap)
            # where does the hyp label change nearest to this point?
            changes = [j for j in range(1, len(words)) if base[j] != base[j - 1]]
            if changes:
                j = min(changes, key=lambda j: abs(j - i)); dist.append(j - i)
    for i in range(1, len(words)):
        if m[i] is not None and m[i - 1] is not None and truth[m[i]]['speaker'] == truth[m[i - 1]]['speaker']:
            within.append(words[i]['start'] - words[i - 1]['end'])
dist = np.array(dist); widths = np.array(widths); within = np.array(within)
print("true changes:", len(dist), " hyp change at the same word gap:", (dist == 0).mean().round(3),
      " off by 1 word:", (np.abs(dist) == 1).mean().round(3), " by 2+:", (np.abs(dist) >= 2).mean().round(3))
print("pause at a true change: p10 %.2f p50 %.2f s;  pause between words of one speaker: p50 %.2f p90 %.2f p99 %.2f s"
      % (np.percentile(widths, 10), np.percentile(widths, 50), np.percentile(within, 50), np.percentile(within, 90), np.percentile(within, 99)))

# ---- A2: snap to the WIDEST pause within the window, only pauses of at least `minw`
def snap2(words, turns, window, minw):
    ts = sorted([dict(t) for t in turns], key=lambda t: t['start'])
    gaps = [((words[i]['end'] + words[i + 1]['start']) / 2 - OFFSET, words[i + 1]['start'] - words[i]['end']) for i in range(len(words) - 1)]
    for k in range(len(ts) - 1):
        a, b = ts[k], ts[k + 1]
        if a['speaker'] == b['speaker'] or b['start'] - a['end'] > 1.0: continue
        centre = (a['end'] + b['start']) / 2
        near = [(g, w) for g, w in gaps if abs(g - centre) <= window and w >= minw]
        if not near: continue
        g = max(near, key=lambda gw: (gw[1], -abs(gw[0] - centre)))[0]
        a['end'] = g; b['start'] = g
    return ts
for w in (0.3, 0.5):
    for minw in (0.1, 0.2, 0.3):
        evaluate(f'A2 widest pause ≥{minw} s within ±{w} s', lambda d, base, w=w, minw=minw: align(d['run']['words'], snap2(d['run']['words'], d['run']['turns'], w, minw)))

# ---- B2: voice at changes with the word and its neighbour on the same side averaged (2-word evidence)
def voice_boundary2(labels, E, margin):
    C = centroids(labels, E); out = list(labels)
    for i in range(1, len(labels)):
        L, R = labels[i - 1], labels[i]
        if L == R or L is None or R is None or L not in C or R not in C: continue
        # the last word of the left run: does it sound like R? the first word of the right run: like L?
        for j, own, other, partner in ((i - 1, L, R, i), (i, R, L, i - 1)):
            e = E[j]
            if np.dot(e, C[other]) - np.dot(e, C[own]) > margin and np.dot(E[partner], C[other]) > np.dot(E[partner], C[own]):
                out[j] = other
    return out
for m in (0.05, 0.1, 0.2):
    evaluate(f'B2 voice at changes, other side agrees (margin {m})', lambda d, base, m=m: voice_boundary2(base, d['E'], m))
