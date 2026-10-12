# Icon feather v2: a gently curved axis with a mirrored vane around it, slanted cut-ins whose apex lies below
# the mouth (the slit leans back toward the base, barbs point to the tip), a hair-thin rachis line that tapers in and
# out inside the vane only, a short shaft with a rounded foot. sym2.py <out.icon> k=v ...
import math, os, sys, json
DST = sys.argv[1]; O = dict(a.split("=") for a in sys.argv[2:])
def opt(k, d): return float(O.get(k, d))
os.makedirs(DST + "/Assets", exist_ok=True)
ANG = math.radians(opt("ang", 52)); BEND = opt("bend", 0.12)
VL, SL = 1.0, opt("sl", 0.16)
W, PEAK, TIPK, BASEK = opt("w", 0.19), opt("peak", 0.5), opt("tipk", 0.85), opt("basek", 1.35)
SHW, SIZE, OC = opt("shw", 0.03), opt("size", 0.68), opt("oc", 0.6)
RACH, R0, R1 = opt("rach", 0.007), opt("r0", 0.04), opt("r1", 0.7)     # rachis line: half width, start, end (u)
SLANT = opt("slant", 1.2)          # apex sits SLANT * mouth width below the mouth's start
CUTS = [tuple(map(float, c.split(":"))) for c in O.get("cuts", "0.30:0.55:-1:0.05,0.62:0.5:-1:0.045,0.44:0.55:1:0.05,0.76:0.4:1:0.04").split(",") if c]
TOT = VL + SL
def axis(t):           # t in [-SL, VL] along the feather; a quadratic curve bulging to the upper left, tip sweeps right
    u = (t + SL) / TOT
    ax, ay = math.cos(ANG), math.sin(ANG); nx, ny = -ay, ax
    off = 4 * BEND * u * (1 - u) * TOT
    return (t * ax + nx * off, t * ay + ny * off)
def normal(t):
    a, b = axis(t - 1e-4), axis(t + 1e-4); dx, dy = b[0] - a[0], b[1] - a[1]; n = math.hypot(dx, dy)
    return (-dy / n, dx / n)
def pt(t, w, side):    # side -1 = upper-left, +1 = lower-right
    x, y = axis(t); nx, ny = normal(t); s = -side
    return (x + nx * s * w, y + ny * s * w)
def prof(u):
    if u <= 0 or u >= 1: return 0.0
    if u < PEAK: return W * math.sin(math.pi / 2 * u / PEAK) ** BASEK
    v = (u - PEAK) / (1 - PEAK); return W * math.cos(math.pi / 2 * v) ** TIPK
def sm(x): x = max(0, min(1, x)); return x * x * (3 - 2 * x)
def shw(t): return SHW * (0.5 + 0.5 * sm((t + SL) / (SL + 0.14)))
SPE, SPP, OV, HAIR, SPK = opt("spe", 0.8), opt("spp", 1.0), opt("ov", 0.004), opt("hair", 0.0), opt("spk", 1.0)
def spine_w(t):   # front piece: shaft, then a rachis that narrows from the vane base to a point at SPE
    if t <= 0: return shw(t)
    # stays visibly thick almost to the end: a power taper (1 - t/SPE)^SPP to a point at the feather's tip
    return shw(0) * (1 - (1 - SPK) * sm(t / 0.18)) * max(0.0, 1 - min(1, t / SPE)) ** SPP
def gap(u):       # the halves stop OV short of the spine's edge, so they tuck under it with no visible seam;
    # beyond the spine's end an optional blue hairline (HAIR) keeps the halves visibly apart up to the tip
    g = spine_w(u) - OV if u < SPE else 0.0
    h = HAIR * min(1, u / 0.1) * max(0.0, (0.97 - u) / 0.97) ** 0.6 if HAIR > 0 else 0.0
    return min(prof(u), max(0.0, g, h))
def edge(side):
    cuts = sorted([c for c in CUTS if c[2] == side])
    us = [i / 800 for i in range(801)]
    out = []
    for u in us:
        c = next((c for c in cuts if c[0] < u < c[0] + c[3]), None)
        if c:
            if not out or out[-1][2] is not c:
                au = max(0.02, c[0] - SLANT * c[3])
                out += [(c[0], prof(c[0]), c), (au, max(gap(au) + 0.01, prof(au) * (1 - c[1])), c),
                        (c[0] + c[3], prof(c[0] + c[3]), c)]
            continue
        out.append((u, prof(u), None))
    return [(u, w, c is not None) for u, w, c in out]
RND = opt("round", 0.0)     # corner radius of the cut-ins (feather lengths); 0 = sharp
def rounded(pts, corner):
    """pts: xy polyline, corner: flags. Each flagged vertex is replaced by a quadratic curve from the point RND
    before it to the point RND after it (measured along the polyline), the vertex as its control point."""
    if RND <= 0: return pts
    out = list(pts); flags = list(corner)
    i = 0
    while i < len(out):
        if not flags[i]: i += 1; continue
        def walk(step):
            d, j = 0.0, i
            while 0 <= j + step < len(out):
                seg = math.dist(out[j], out[j + step])
                if d + seg >= RND:
                    f = (RND - d) / seg
                    return j, (out[j][0] + (out[j + step][0] - out[j][0]) * f, out[j][1] + (out[j + step][1] - out[j][1]) * f)
                d += seg; j += step
            return j, out[j]
        ja, A = walk(-1); jb, B = walk(1)
        V = out[i]
        curve = [((1 - t) ** 2 * A[0] + 2 * (1 - t) * t * V[0] + t * t * B[0],
                  (1 - t) ** 2 * A[1] + 2 * (1 - t) * t * V[1] + t * t * B[1]) for t in [k / 16 for k in range(17)]]
        # ja..jb (inclusive) are the points between A and B, the corner among them: all replaced by the curve
        out[ja:jb + 1] = curve
        flags[ja:jb + 1] = [False] * len(curve)
        i = ja + len(curve)
    return out
L, R = edge(-1), edge(1)
Lxy = rounded([pt(u * VL, w, -1) for u, w, _ in L], [f for _, _, f in L])
Rxy = rounded([pt(u * VL, w, 1) for u, w, _ in R], [f for _, _, f in R])
if True:
    # the vane as two halves split by the rachis line where it exists; joined (one shape) below and above it
    inner = [i / 600 for i in range(601)]
    left = Lxy + [pt(u * VL, gap(u), -1) for u in inner[::-1]]
    right = Rxy + [pt(u * VL, gap(u), 1) for u in inner[::-1]]
    polys = [left, right]
else:
    polys = [Lxy + Rxy[::-1]]
sh = [(t, spine_w(t)) for t in [-SL + (SPE + SL) * i / 400 for i in range(401)]]
foot = [(-SL - SHW * 0.5 * math.sin(a), SHW * 0.5 * math.cos(a)) for a in [k * math.pi / 20 for k in range(21)]]
polys.append([pt(t, w, -1) for t, w in sh][::-1] + [pt(t, abs(w), -1 if w >= 0 else 1) for t, w in foot] + [pt(t, w, 1) for t, w in sh])
def centroid(poly):
    A = cx = cy = 0
    for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
        c = x0 * y1 - x1 * y0; A += c; cx += (x0 + x1) * c; cy += (y0 + y1) * c
    return abs(A) / 2, (cx / (3 * A), cy / (3 * A))
xs = [p[0] for q in polys for p in q]; ys = [p[1] for q in polys for p in q]
sc = SIZE * 1024 / max(max(xs) - min(xs), max(ys) - min(ys))
tot = mx = my = 0
for q in polys:
    a, (cx, cy) = centroid(q); tot += a; mx += a * cx; my += a * cy
mx /= tot; my /= tot; bx, by = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
cx, cy = bx + (mx - bx) * OC, by + (my - by) * OC
def tr(p): return (512 + (p[0] - cx) * sc + opt("dx", 0), 512 - (p[1] - cy) * sc + opt("dy", 0))
def path(q): return "M " + " L ".join("%.1f,%.1f" % tr(p) for p in q) + " Z"
def svg(name, qs): open(DST + "/Assets/" + name, "w").write('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    + "".join(f'<path d="{path(q)}" fill="#000000"/>' for q in qs) + "</svg>\n")
# layered output: upper-left half, lower-right half, shaft (+ spine) as separate SVGs for separate glass layers

# Nested feathers (the Home icon's stacked houses): the same feather, narrower by a fixed amount (its long edges run
# parallel to the feather's), its cut-ins at the same places and of the same wedge form, their depth scaled with the
# narrower vane (an inward offset of the outline widened every cut-in into a wave). Same corner rounding.
INSETS = [float(x) for x in O.get("insets", "0.2,0.42").split(",") if x]
def inset_edge(side, d):
    cuts = sorted([c for c in CUTS if c[2] == side])
    out = []
    for u in [i / 800 for i in range(801)]:
        c = next((c for c in cuts if c[0] < u < c[0] + c[3]), None)
        if c:
            if not out or out[-1][2] is not c:
                au = max(0.02, c[0] - SLANT * c[3])
                out += [(c[0], prof(c[0]) - d, c), (au, (prof(au) - d) * (1 - c[1]), c), (c[0] + c[3], prof(c[0] + c[3]) - d, c)]
            continue
        out.append((u, prof(u) - d, None))
    keep = [i for i, (u, w, c) in enumerate(out) if w > 0]
    out = out[keep[0]:keep[-1] + 1]
    return [(u, max(w, 0.004), c is not None) for u, w, c in out]
def inset_poly(share):
    d = share * W
    l, r = inset_edge(-1, d), inset_edge(1, d)
    lx = rounded([pt(u * VL, w, -1) for u, w, _ in l], [f for _, _, f in l])
    rx = rounded([pt(u * VL, w, 1) for u, w, _ in r], [f for _, _, f in r])
    return lx + rx[::-1]
body = Lxy + Rxy[::-1]
svg("body.svg", [body, polys[2]])
for name, share in zip(("inner.svg", "core.svg"), INSETS):
    svg(name, [inset_poly(share)])
