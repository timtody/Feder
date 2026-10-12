import sys, subprocess, xml.etree.ElementTree as ET, collections
trace=sys.argv[1]
xml=subprocess.run(['xcrun','xctrace','export','--input',trace,'--xpath','/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],capture_output=True,text=True).stdout
root=ET.fromstring(xml)
ids={}
def res(el):
    if 'ref' in el.attrib: return ids[el.attrib['ref']]
    if 'id' in el.attrib: ids[el.attrib['id']]=el
    for ch in list(el): res(ch)
    return el
rows=[]
for row in root.iter('row'):
    t=None; thread=None; bt=None; weight=1
    for c in list(row):
        c=res(c)
        if c.tag=='sample-time': t=int(c.text)
        elif c.tag=='thread': thread=c
        elif c.tag in ('backtrace','tagged-backtrace'): bt=c
        elif c.tag=='weight': weight=int(c.text)
    if thread is None: continue
    if 'Main Thread' not in thread.attrib.get('fmt',''): continue
    frames=[]
    if bt is not None:
        for f in bt.iter('frame'):
            f=res(f)
            frames.append(f.attrib.get('name','?'))
    rows.append((t,frames))
print("main-thread samples:", len(rows))
def isapp(n): return n.startswith('Recorder.') or 'Recorder.' in n[:40] or n.startswith('closure #') and 'Recorder' in n
inner=collections.Counter(); incl=collections.Counter(); leaf=collections.Counter(); outer=collections.Counter()
for t,frames in rows:
    if not frames: continue
    leaf[frames[0]]+=1
    app=[f for f in frames if 'Recorder.' in f]
    if app:
        inner[app[0]]+=1; outer[app[-1]]+=1
    for f in set(frames):
        if 'Recorder.' in f or 'SwiftData' in f or 'AVAudioSession' in f or 'AVAudioEngine' in f or 'AudioSession' in f: incl[f]+=1
print("\n== innermost frame in our module (self+callees time attributed to the deepest app frame) ==")
for n,c in inner.most_common(45): print("%5d  %s"%(c,n[:170]))
print("\n== inclusive counts of selected frames ==")
for n,c in sorted(incl.items(),key=lambda x:-x[1])[:70]: print("%5d  %s"%(c,n[:170]))
print("\n== top leaves on main ==")
for n,c in leaf.most_common(20): print("%5d  %s"%(c,n[:120]))
# timeline of app activity in 100 ms buckets
if rows:
    t0=rows[0][0]
    b=collections.Counter(int((t-t0)/1e8) for t,f in rows if f)
    print("\n== main-thread samples per 100 ms (bucket:count), from the first sample ==")
    print(" ".join("%d:%d"%(k,v) for k,v in sorted(b.items()) if v>=10))
