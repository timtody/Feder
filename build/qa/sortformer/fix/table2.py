# Aggregates build/qa/sortformer/fix/runs: per configuration (model x condition x seed) the overall figures, the means
# and ranges over the four noise seeds, and the per-meeting "right when first labelled". Run: python3 -I table2.py <runs dir>
import json, os, sys, statistics, glob

R = sys.argv[1]

def pct(values, p):
    if not values: return float('nan')
    v = sorted(values); r = p * (len(v) - 1); lo = int(r); hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (r - lo)

def load(d):
    f = glob.glob(os.path.join(R, d, 'results-*.json'))
    return json.load(open(f[0])) if f else None

def overall(rs):
    w = sum(r['words'] for r in rs)
    delays = [d for r in rs for d in r['delays']]
    return dict(first=100 * sum(r['liveCorrect'] for r in rs) / w, stop=100 * sum(r['finalCorrect'] for r in rs) / w,
                spk1=100 * sum(r['speaker1Words'] for r in rs) / w, truth1=100 * sum(r['firstSpeakerWords'] for r in rs) / w,
                p50=pct(delays, .5), p90=pct(delays, .9), n=len(delays), missed=sum(r['missed'] for r in rs),
                cpu=sum(r['cpuSeconds'] for r in rs) / sum(r['audioSeconds'] for r in rs),
                wall=sum(r['wallSeconds'] for r in rs) / sum(r['audioSeconds'] for r in rs),
                lag=statistics.median(r['lagP50'] for r in rs), gaps=sum(r['gaps'] for r in rs), meetings=len(rs))

configs = sorted(d for d in os.listdir(R) if os.path.isdir(os.path.join(R, d)))
res = {d: load(d) for d in configs}
print('| run | meetings | first labelled | at Stop | Speaker 1 (truth) | new spk p50 / p90 (n) | missed | CPU s/s | wall s/s | lag p50 | gaps |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for d in configs:
    if not res[d]: print(f'| {d} | – |'); continue
    o = overall(res[d])
    print(f"| {d} | {o['meetings']} | {o['first']:.1f} % | {o['stop']:.1f} % | {o['spk1']:.1f} % ({o['truth1']:.1f} %) | {o['p50']:.1f} / {o['p90']:.1f} s ({o['n']}) | {o['missed']} | {o['cpu']:.3f} | {o['wall']:.3f} | {o['lag']:.2f} s | {o['gaps']} |")

print('\nNoise seeds (55, 1, 2, 3): mean [min-max]')
for model in ('lseend', 'sortformer'):
    os_ = [overall(res[f'{model}-n{s}']) for s in ('55', '1', '2', '3') if res.get(f'{model}-n{s}')]
    if not os_: continue
    def agg(k, f='.1f'):
        v = [o[k] for o in os_]
        return f"{statistics.mean(v):{f}} [{min(v):{f}}-{max(v):{f}}]"
    print(f"{model} ({len(os_)} seeds): first {agg('first')} %, Stop {agg('stop')} %, Speaker 1 {agg('spk1')} %, "
          f"new p50 {agg('p50')} s, p90 {agg('p90')} s, missed {agg('missed', '.2f')}, lag {agg('lag', '.2f')} s")

print('\nPer meeting, right when first labelled (%): clean | noise seeds 55/1/2/3')
meetings = sorted({r['meeting'] for rs in res.values() if rs for r in rs})
print('| meeting | LS-EEND clean | LS-EEND noise | Sortformer clean | Sortformer noise | CPU only clean |')
print('|---|---|---|---|---|---|')
def cell(d, m):
    rs = res.get(d)
    r = next((x for x in rs if x['meeting'] == m), None) if rs else None
    return 100 * r['liveCorrect'] / r['words'] if r else None
for m in meetings:
    row = [m]
    for model in ('lseend', 'sortformer'):
        c = cell(f'{model}-clean', m); row.append(f'{c:.1f}' if c is not None else '–')
        ns = [cell(f'{model}-n{s}', m) for s in ('55', '1', '2', '3')]; ns = [x for x in ns if x is not None]
        row.append('/'.join(f'{x:.1f}' for x in ns) or '–')
    c = cell('cpuonly-clean', m); row.append(f'{c:.1f}' if c is not None else '–')
    print('| ' + ' | '.join(row) + ' |')
