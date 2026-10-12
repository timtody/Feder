"""Time Profiler samples per interaction: aggregates the main-thread samples that fall inside each "Press" signpost
interval (InteractionTrace, Points of Interest) and prints the heaviest app frames per press.
usage: python3 tp4.py <trace> [maxFramesPerPress]"""
import sys, subprocess, xml.etree.ElementTree as ET, collections, re
trace = sys.argv[1]; top = int(sys.argv[2]) if len(sys.argv) > 2 else 18
binary = '/Users/julius.taylor/projects/recorder/build/DerivedDataSwipe/Build/Products/Debug-iphonesimulator/Feder.app/Feder.debug.dylib'

def export(xpath):
    return subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', xpath], capture_output=True, text=True).stdout

ids = {}
def res(el):
    if 'ref' in el.attrib: return ids[el.attrib['ref']]
    if 'id' in el.attrib: ids[el.attrib['id']] = el
    for ch in list(el): res(ch)
    return el

# --- signpost intervals (Press: Begin/End events paired by identifier; the name is the metadata)
spans = []
sp = export('/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]')
begins = {}
if sp.strip():
    root = ET.fromstring(sp)
    for row in root.iter('row'):
        cols = {}
        for c in list(row):
            c = res(c); cols.setdefault(c.tag, []).append(c)
        name = (cols.get('signpost-name') or [None])[0]
        if name is None or name.text != 'Press': continue
        kind = cols['event-type'][0].text
        t = int(cols['event-time'][0].text)
        ident = cols['os-signpost-identifier'][0].text
        meta = (cols.get('os-log-metadata') or [None])[0]
        label = (meta.attrib.get('fmt') if meta is not None else '?').split(' ')[0]
        if kind == 'Begin': begins[ident] = (t, label)
        elif kind == 'End' and ident in begins:
            t0, label = begins.pop(ident)
            spans.append((t0, t, label))
spans.sort()
print("press intervals:", [(l, round((e - s) / 1e6, 1)) for s, e, l in spans])

# --- main-thread samples
xml = export('/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]')
root = ET.fromstring(xml)
rows = []
for row in root.iter('row'):
    t = None; thread = None; bt = None
    for c in list(row):
        c = res(c)
        if c.tag == 'sample-time': t = int(c.text)
        elif c.tag == 'thread': thread = c
        elif c.tag in ('backtrace', 'tagged-backtrace'): bt = c
    if thread is None or 'Main Thread' not in thread.attrib.get('fmt', ''): continue
    frames = []
    if bt is not None:
        for f in list(bt):
            f = res(f)
            if f.tag != 'frame': continue
            b = None
            for ch in list(f):
                ch = res(ch)
                if ch.tag == 'binary': b = ch
            frames.append((f.attrib.get('name', '?'), f.attrib.get('addr'), b.attrib.get('name') if b is not None else None, b.attrib.get('load-addr') if b is not None else None))
    rows.append((t, frames))
addrs = sorted({a for t, fr in rows for n, a, bn, la in fr if bn == 'Feder.debug.dylib'})
load = next((la for t, fr in rows for n, a, bn, la in fr if bn == 'Feder.debug.dylib'), None)
sym = {}
if addrs and load:
    out = subprocess.run(['atos', '-o', binary, '-arch', 'arm64', '-l', load] + addrs, capture_output=True, text=True).stdout.splitlines()
    sym = dict(zip(addrs, out))
def name(fr):
    n, a, bn, la = fr
    if bn == 'Feder.debug.dylib': return 'APP ' + re.sub(r' \(in Feder\.debug\.dylib\).*', '', sym.get(a, n))
    return n
interesting = ('SwiftData', 'NSManagedObject', 'AVAudioSession', 'AVAudioEngine', 'UIKeyboard', 'UITabBar', 'UIPresentation', 'CoreData', 'AG::Graph', 'UIViewController', '_UI', 'SwiftUI', 'Observation')
for s, e, label in spans:
    inside = [fr for t, fr in rows if s <= t <= e]
    if not inside: continue
    inner = collections.Counter(); incl = collections.Counter(); leaf = collections.Counter()
    for fr in inside:
        names = [name(f) for f in fr]
        if names: leaf[names[0]] += 1
        app = [n for n in names if n.startswith('APP ')]
        if app: inner[app[0]] += 1
        for n in set(names):
            if n.startswith('APP ') or any(k in n for k in interesting): incl[n] += 1
    print("\n######## %s: %d main-thread ms sampled in %.0f ms" % (label, len(inside), (e - s) / 1e6))
    print("-- innermost app frame --")
    for n, c in inner.most_common(top): print("%5d  %s" % (c, n[:160]))
    print("-- inclusive (app + selected system) --")
    for n, c in sorted(incl.items(), key=lambda x: -x[1])[:top * 2]: print("%5d  %s" % (c, n[:160]))
    print("-- leaves --")
    for n, c in leaf.most_common(8): print("%5d  %s" % (c, n[:120]))
