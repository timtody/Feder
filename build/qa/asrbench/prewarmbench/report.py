"""FED-212: the table from out/results.jsonl (run.sh). The wait after Stop until the transcript is done = Parakeet's
words step (load + transcription) + Nemotron's speakers; cold = no prewarm after an update, warm = prewarmed."""
import json, statistics, sys
from collections import defaultdict

rows = defaultdict(lambda: defaultdict(list))
for line in open(sys.argv[1] if len(sys.argv) > 1 else "out/results.jsonl"):
    d = json.loads(line)
    rows[d["minutes"]][d["case"]].append(d["r"])

med = statistics.median
print(f"{'length':>7} | {'cold load':>9} {'warm load':>9} {'transcribe':>10} {'speakers':>8} | "
      f"{'wait cold':>9} {'wait warm':>9} {'saved':>6} {'speedup':>7}")
for minutes in sorted(rows):
    c = rows[minutes]
    cold_load = med(r["load"] for r in c["cold"])
    warm_load = med(r["load"] for r in c["warm"])
    transcribe = med(r["run"] for r in c["cold"] + c["warm"])
    speakers = med(r["run"] for r in c["speakers"])
    cold = cold_load + transcribe + speakers
    warm = warm_load + transcribe + speakers
    label = f"{minutes * 60:.0f} s" if minutes < 1 else f"{minutes:g} min"
    print(f"{label:>7} | {cold_load:9.2f} {warm_load:9.2f} {transcribe:10.2f} {speakers:8.2f} | "
          f"{cold:9.2f} {warm:9.2f} {cold - warm:6.2f} {cold / warm:6.1f}x")
