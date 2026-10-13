#!/bin/zsh
# lock-icon.sh: App Lock's feather (AppLockView) from the app icon's own feather, Recorder/AppIcon.icon/Assets/body.svg
# (read only), cropped to the feather into Recorder/Assets.xcassets/AppLockFeather as a vector template image, so the
# view draws it white on the blue at any size. The whole icon (squircle, glass) on the blue was replaced by the feather
# alone at the user's request; Icon Composer's renderer can't leave out the squircle (with a fill matching the screen
# its rim and lighting still showed). Rerun it whenever the feather in the icon changes, and commit the SVG.
cd /Users/julius.taylor/projects/recorder || exit 1
out=Recorder/Assets.xcassets/AppLockFeather.imageset
mkdir -p $out
python3 - Recorder/AppIcon.icon/Assets/body.svg $out/AppLockFeather.svg <<'PY' || exit 1
import re, sys
svg = open(sys.argv[1]).read()
paths = re.findall(r'<path[^>]*/>', svg)
points = [float(n) for p in paths for n in re.findall(r'-?\d+(?:\.\d+)?', re.search(r' d="([^"]+)"', p).group(1))]
xs, ys = points[0::2], points[1::2]
pad = 4                                    # the edge's antialiasing stays inside the image
x, y = min(xs) - pad, min(ys) - pad
w, h = max(xs) - min(xs) + 2 * pad, max(ys) - min(ys) + 2 * pad
open(sys.argv[2], "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.1f}" height="{h:.1f}" viewBox="{x:.1f} {y:.1f} {w:.1f} {h:.1f}">'
    + "".join(paths) + "</svg>\n")
PY
cat > $out/Contents.json <<'JSON'
{
  "images" : [
    {
      "filename" : "AppLockFeather.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
JSON
ls -l $out
