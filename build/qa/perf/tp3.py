import sys, subprocess, xml.etree.ElementTree as ET, collections, re
trace=sys.argv[1]; binary='/Users/julius.taylor/projects/recorder/build/DerivedDataSwipe/Build/Products/Debug-iphonesimulator/Feder.app/Feder.debug.dylib'
xml=open(trace.replace('.trace','-profile.xml')).read() if False else subprocess.run(['xcrun','xctrace','export','--input',trace,'--xpath','/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],capture_output=True,text=True).stdout
root=ET.fromstring(xml)
ids={}; bins={}
def res(el):
    if 'ref' in el.attrib: return ids[el.attrib['ref']]
    if 'id' in el.attrib: ids[el.attrib['id']]=el
    for ch in list(el): res(ch)
    return el
rows=[]
for row in root.iter('row'):
    t=None; thread=None; bt=None
    for c in list(row):
        c=res(c)
        if c.tag=='sample-time': t=int(c.text)
        elif c.tag=='thread': thread=c
        elif c.tag in ('backtrace','tagged-backtrace'): bt=c
    if thread is None or 'Main Thread' not in thread.attrib.get('fmt',''): continue
    frames=[]
    if bt is not None:
        for f in list(bt):
            f=res(f)
            if f.tag!='frame': continue
            b=None
            for ch in list(f):
                ch=res(ch)
                if ch.tag=='binary': b=ch
            frames.append((f.attrib.get('name','?'), f.attrib.get('addr'), b.attrib.get('name') if b is not None else None, b.attrib.get('load-addr') if b is not None else None))
    rows.append((t,frames))
# symbolicate app frames with atos
addrs=sorted({a for t,fr in rows for n,a,bn,la in fr if bn=='Feder.debug.dylib'})
load=next((la for t,fr in rows for n,a,bn,la in fr if bn=='Feder.debug.dylib'),None)
sym={}
if addrs:
    out=subprocess.run(['atos','-o',binary,'-arch','arm64','-l',load]+addrs,capture_output=True,text=True).stdout.splitlines()
    sym=dict(zip(addrs,out))
def name(fr):
    n,a,bn,la=fr
    if bn=='Feder.debug.dylib': return 'APP '+re.sub(r' \(in Feder\.debug\.dylib\).*','',sym.get(a,n))
    return n
print("main samples", len(rows), "app frames", len(addrs), "load", load)
inner=collections.Counter(); incl=collections.Counter(); outer=collections.Counter()
for t,fr in rows:
    names=[name(f) for f in fr]
    app=[n for n in names if n.startswith('APP ')]
    if app:
        inner[app[0]]+=1; outer[app[-1]]+=1
        for n in set(app): incl[n]+=1
    for n in set(names):
        if any(k in n for k in ('SwiftData','AVAudioSession','AVAudioEngine','ModelContext','NSManagedObject','UIKeyboard','UITabBar','_UIInput','SpeechAnalyzer')): incl[n]+=1
print("\n== innermost app frame (ms) ==")
for n,c in inner.most_common(50): print("%5d  %s"%(c,n[:180]))
print("\n== inclusive (ms) of app frames and selected system frames ==")
for n,c in sorted(incl.items(),key=lambda x:-x[1])[:80]: print("%5d  %s"%(c,n[:180]))
print("\n== outermost app frame (which path) ==")
for n,c in outer.most_common(20): print("%5d  %s"%(c,n[:180]))
