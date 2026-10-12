# icon.json for <icon>: the current app icon's setup (its feather group unchanged), with the two nested shapes as
# their own glass groups in front of it (the first group is the frontmost). compose.py <icon> k=v ...
import json, sys, copy
DST = sys.argv[1]; O = dict(a.split("=") for a in sys.argv[2:])
base = json.load(open("/Users/julius.taylor/projects/recorder/Recorder/AppIcon.icon/icon.json"))
feather = next(g for g in base["groups"] if any(l.get("image-name") == "body.svg" for l in g["layers"]))   # the feather's own group
pos = feather["layers"][0]["position"]
def group(name, image, translucency, shadow):
    g = copy.deepcopy(feather)
    g["name"] = name
    g["layers"] = [{"fill": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"}, "hidden": False, "image-name": image,
                    "name": name, "position": copy.deepcopy(pos)}]
    g["translucency"] = {"enabled": True, "value": translucency}
    g["shadow"] = {"kind": "layer-color", "opacity": shadow}
    return g
base["groups"] = [group("core", "core.svg", float(O.get("t2", 0.5)), float(O.get("s2", 0.5))),
                  group("inner", "inner.svg", float(O.get("t1", 0.55)), float(O.get("s1", 0.5))), feather]
json.dump(base, open(DST + "/icon.json", "w"), indent=2)
