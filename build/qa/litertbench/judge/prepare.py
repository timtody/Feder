#!/usr/bin/env python3
"""Blind judging packets from a Feder Lab report (FED-153).

usage: prepare.py <bench-….json> <out-dir> [--seed N]

For every input of the report: one packet <out-dir>/<n>-<input>.md with the transcript, its answer key when it is a
bench text (keys/<file>.key.md next to this script), and each model's summary under a shuffled letter. Greedy decoding
gives the same summary in every repetition, so the first usable one is judged; a model that never produced one is
shown as "(no summary)". <out-dir>/mapping.json keeps the letters' models and is read only by aggregate.py.
"""
import json
import random
import sys
from pathlib import Path

KEYS = Path(__file__).resolve().parent / "keys"


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 153
    if len(args) < 2:
        sys.exit(__doc__)
    report = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    out = Path(args[1])
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    models = sorted({run["model"] for run in report["runs"]})
    mapping = {}
    for index, item in enumerate(report["inputs"], 1):
        runs = [r for r in report["runs"] if r["input"] == item["id"]]
        entries = []
        for model in models:
            mine = sorted((r for r in runs if r["model"] == model), key=lambda r: r["repetition"])
            if not mine:
                continue
            usable = next((r for r in mine if r.get("summary")), None)
            failures = sum(1 for r in mine if not r.get("summary"))
            entries.append({"model": model, "title": usable.get("title") if usable else None,
                            "summary": usable["summary"] if usable else None,
                            "failures": failures, "runs": len(mine)})
        rng.shuffle(entries)
        letters = "ABCDEFGH"
        mapping[item["id"]] = {letters[i]: e for i, e in enumerate(entries)}
        name = item["id"].split(":", 1)[1]
        key = KEYS / f"{name}.key.md" if item["isBenchText"] else None
        lines = [f"# Judging packet {index}: {item['id']}", "",
                 f"Input: {item['name']} ({item['characters']} characters)", ""]
        lines += ["## Answer key", "", key.read_text(encoding="utf-8").strip(), ""] if key and key.exists() \
            else ["## Answer key", "", "(none: one of the user's own transcripts; judge against the transcript alone)", ""]
        lines += ["## Summaries", ""]
        for letter, entry in mapping[item["id"]].items():
            lines.append(f"### {letter}")
            if entry["summary"]:
                lines += [f"Title: {entry['title'] or '(no title)'}", f"Summary: {entry['summary']}", ""]
            else:
                lines += ["(no summary)", ""]
        lines += ["## Transcript", "", item["text"], ""]
        (out / f"{index:02d}-{name[:60]}.md").write_text("\n".join(lines), encoding="utf-8")
    (out / "mapping.json").write_text(json.dumps(mapping, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{len(mapping)} packets, models {', '.join(models)}, seed {seed} -> {out}")


if __name__ == "__main__":
    main()
