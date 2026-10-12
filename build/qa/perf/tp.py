import sys, subprocess, xml.etree.ElementTree as ET, collections, re
trace=sys.argv[1]; wantmod = 'Recorder'
xml=subprocess.run(['xcrun','xctrace','export','--input',trace,'--xpath','/trace-toc/run[@number="1"]/data/table[@schema="time-sample"]'],capture_output=True,text=True).stdout
root=ET.fromstring(xml)
ids={}  # id -> element (for ref resolution)
def resolve(el):
    if 'ref' in el.attrib: return ids[el.attrib['ref']]
    if 'id' in el.attrib: ids[el.attrib['id']]=el
    return el
main=0; total=0
leaf=collections.Counter(); anyframe=collections.Counter(); first_app=collections.Counter()
timeline=[]  # (t, app frame)
for row in root.iter('row'):
    cols=list(row)
    # columns: sample-time, thread, process, core, thread-state, weight, backtrace
    t=None; thread=None; bt=None
    for c in cols:
        c=resolve(c)
        if c.tag=='sample-time': t=int(c.text)
        elif c.tag=='thread': thread=c
        elif c.tag=='backtrace': bt=c
    if thread is None: continue
    fmt=thread.attrib.get('fmt','')
    for ch in list(thread):
        resolve(ch)
    total+=1
    if 'Main Thread' not in fmt: continue
    main+=1
    frames=[]
    if bt is not None:
        for f in list(bt):
            f=resolve(f)
            if f.tag=='frame': frames.append(f.attrib.get('name','?'))
    if not frames: continue
    leaf[frames[0]]+=1
    seen=set()
    for fr in frames:
        if fr in seen: continue
        seen.add(fr); anyframe[fr]+=1
    app=[f for f in frames if ('Recorder' in f or 'Scribe' in f) and 'specialized' not in f[:12]]
    # the outermost app frame (closest to the run loop) tells the interaction; the innermost tells the work
    if app:
        first_app[app[0]]+=1
        timeline.append((t, app[-1], app[0]))
print("samples total", total, "main", main, "(1 ms each)")
print("\n== innermost app frame (what the main thread was doing in our code) ==")
for n,c in first_app.most_common(40): print("%5d  %s"%(c,n[:150]))
print("\n== any frame containing our symbols, inclusive ==")
appinc=[(n,c) for n,c in anyframe.items() if 'Recorder.' in n or 'Scribe' in n]
for n,c in sorted(appinc,key=lambda x:-x[1])[:60]: print("%5d  %s"%(c,n[:150]))
print("\n== top leaf frames overall on main ==")
for n,c in leaf.most_common(25): print("%5d  %s"%(c,n[:120]))
# busy stretches: consecutive main samples in ms buckets
if timeline:
    timeline.sort()
    t0=timeline[0][0]
    buckets=collections.Counter(int((t-t0)/1e8) for t,_,_ in timeline)  # 100 ms buckets
    print("\n== main-thread samples in our code per 100 ms since first app sample ==")
    print(" ".join("%d:%d"%(k,v) for k,v in sorted(buckets.items()) if v>5))
