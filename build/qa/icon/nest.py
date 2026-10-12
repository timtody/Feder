# The feather (sym5.py's body, with rounder cut-in corners) plus two smaller copies nested inside it, their edges
# parallel to the feather's (inward offsets), like the stacked houses of the Apple Home icon.
# nest.py <out.icon> round=<r> d1=<share> d2=<share> soft=<share>
import sys, re, subprocess, math, os
from shapely.geometry import Polygon, MultiPolygon
OUT = sys.argv[1]; O = dict(a.split("=") for a in sys.argv[2:])
RND = O.get("round", "0.024"); D1, D2 = float(O.get("d1", 0.28)), float(O.get("d2", 0.56)); SOFT = float(O.get("soft", 0.12))
HERE = os.path.dirname(os.path.abspath(__file__))
subprocess.run(["python3", HERE + "/sym5.py", OUT, "bend=0.14", "w=0.2", "rach=0.0095",
                "cuts=0.34:0.45:-1:0.09,0.64:0.42:-1:0.08,0.54:0.58:1:0.105", "slant=0.3", "spp=0.55", "spe=0.995",
                "hair=0", "spk=0.78", "round=" + RND], check=True)
for f in ("vane_far.svg", "vane_near.svg", "shaft.svg"):
    os.remove(f"{OUT}/Assets/{f}")
paths = re.findall(r'd="([^"]+)"', open(f"{OUT}/Assets/body.svg").read())
def pts(d): return [tuple(map(float, p.split(","))) for p in re.findall(r"[-\d.]+,[-\d.]+", d)]
vane = Polygon(pts(paths[0])).buffer(0)
# the depth of the vane: its widest inscribed circle's radius (by bisection on the inward offset)
lo, hi = 0.0, 200.0
for _ in range(30):
    mid = (lo + hi) / 2
    lo, hi = (mid, hi) if not vane.buffer(-mid).is_empty else (lo, mid)
R = lo
def largest(g): return max(g.geoms, key=lambda p: p.area) if isinstance(g, MultiPolygon) else g
def inset(share):
    d, r = share * R, SOFT * R                      # offset by d; convex corners rounded with radius r (an opening)
    return largest(vane.buffer(-(d + r), join_style=1, resolution=32).buffer(r, join_style=1, resolution=32))
def path(p): return "M " + " L ".join("%.1f,%.1f" % c for c in list(p.exterior.coords)[:-1]) + " Z"
for name, share in (("inner.svg", D1), ("core.svg", D2)):
    open(f"{OUT}/Assets/{name}", "w").write('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f'<path d="{path(inset(share))}" fill="#000000"/></svg>\n')
print(f"depth {R:.1f} px; insets {D1 * R:.1f} and {D2 * R:.1f} px")
