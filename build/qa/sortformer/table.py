# Per-meeting and overall table from the bench's results-*.json (ane/ = the app's configuration; cpuonly/ = Sortformer
# on the CPU only, for its cost). Run: python3 -I table.py <bench dir>
import json, sys, os, statistics

base = sys.argv[1]
runs = [('LS-EEND', 'ane/results-lseend-clean.json', 'ane/results-lseend--55.json'),
        ('Sortformer (CPU+ANE)', 'ane/results-sortformer-clean.json', 'ane/results-sortformer--55.json'),
        ('Sortformer (CPU only)', 'cpuonly/results-sortformer-clean.json', 'cpuonly/results-sortformer--55.json')]

def pct(values, p):
    if not values: return float('nan')
    v = sorted(values); r = p * (len(v) - 1); lo = int(r); hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (r - lo)

data = {}
for name, clean, noisy in runs:
    for cond, path in (('clean', clean), ('noise -55 dBFS', noisy)):
        p = os.path.join(base, path)
        if os.path.exists(p): data[(name, cond)] = json.load(open(p))

meetings = sorted({m['meeting'] for rs in data.values() for m in rs})
print('Per meeting: words right at Stop / as first shown live; new speakers labelled after (s); live speakers found')
for cond in ('clean', 'noise -55 dBFS'):
    print(f'\n### {cond}')
    header = '| meeting | ' + ' | '.join(f'{n}' for n, _, _ in runs if (n, cond) in data) + ' |'
    print(header); print('|' + '---|' * (header.count('|') - 1))
    for m in meetings:
        cells = []
        for n, _, _ in runs:
            if (n, cond) not in data: continue
            r = next((x for x in data[(n, cond)] if x['meeting'] == m), None)
            if r is None: cells.append('–'); continue
            d = ','.join(f'{x:.1f}' for x in r['delays']) + (f' +{r["missed"]} missed' if r['missed'] else '')
            cells.append(f"{100*r['finalCorrect']/r['words']:.1f} / {100*r['liveCorrect']/r['words']:.1f} %, new {d or '–'}, {r['liveSpeakers']}/{r['speakers']} spk")
        print(f'| {m} | ' + ' | '.join(cells) + ' |')

print('\n### Overall')
print('| model | condition | right at Stop | right as first shown | words under Speaker 1 (truth) | new speaker p50 / p90 | missed | CPU s per s of audio | snapshot lag p50 | gaps |')
print('|---|---|---|---|---|---|---|---|---|---|')
for (n, cond), rs in data.items():
    words = sum(r['words'] for r in rs)
    delays = [d for r in rs for d in r['delays']]
    print(f"| {n} | {cond} | {100*sum(r['finalCorrect'] for r in rs)/words:.1f} % | {100*sum(r['liveCorrect'] for r in rs)/words:.1f} % | "
          f"{100*sum(r['speaker1Words'] for r in rs)/words:.1f} % ({100*sum(r['firstSpeakerWords'] for r in rs)/words:.1f} %) | "
          f"{pct(delays, .5):.1f} / {pct(delays, .9):.1f} s (n {len(delays)}) | {sum(r['missed'] for r in rs)} | "
          f"{sum(r['cpuSeconds'] for r in rs)/sum(r['audioSeconds'] for r in rs):.3f} | {statistics.median(r['lagP50'] for r in rs):.2f} s | {sum(r['gaps'] for r in rs)} |")
    by_mode = {}
    for r in rs:
        mode = r['meeting'].split('_')[1]
        a = by_mode.setdefault(mode, [0, 0, 0])
        a[0] += r['words']; a[1] += r['finalCorrect']; a[2] += r['liveCorrect']
    print('|  | ' + ', '.join(f"{k}: {100*v[1]/v[0]:.1f} / {100*v[2]/v[0]:.1f} %" for k, v in sorted(by_mode.items())) + ' | | | | | | | | |')
