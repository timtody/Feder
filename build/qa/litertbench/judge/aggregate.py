#!/usr/bin/env python3
"""Unblind and average the judges' scores (FED-153).

usage: aggregate.py <packet-dir> <judgements-dir> <bench-….json>

<judgements-dir> holds one JSON file per packet in rubric.md's shape. Prints per model: the mean of every score, overall
and by input length (short < 8,000 characters, medium < 30,000, long), how often it ranked first, its failures, and
every error the judges listed.
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

FIELDS = ["overall", "coverage", "accuracy", "specificity", "language", "form", "title"]


def bucket(characters: int) -> str:
    return "short" if characters < 8_000 else "medium" if characters < 30_000 else "long"


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    mapping = json.loads((Path(sys.argv[1]) / "mapping.json").read_text(encoding="utf-8"))
    report = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
    sizes = {i["id"]: i["characters"] for i in report["inputs"]}
    scores = defaultdict(lambda: defaultdict(list))         # model -> field or bucket field -> values
    firsts, errors, judged = defaultdict(int), defaultdict(list), 0
    for path in sorted(Path(sys.argv[2]).glob("*.json")):
        judgement = json.loads(path.read_text(encoding="utf-8"))
        letters = mapping.get(judgement["input"])
        if not letters:
            print(f"skipped {path.name}: unknown input {judgement['input']}")
            continue
        judged += 1
        size = bucket(sizes.get(judgement["input"], 0))
        for letter, score in judgement["scores"].items():
            model = letters[letter]["model"]
            for field in FIELDS:
                scores[model][field].append(score[field])
            scores[model][f"overall:{size}"].append(score["overall"])
            errors[model] += [f"{judgement['input']}: {e}" for e in score.get("errors", [])]
        if judgement.get("ranking"):
            firsts[letters[judgement["ranking"][0]]["model"]] += 1
    print(f"{judged} inputs judged\n")
    header = "| model | " + " | ".join(FIELDS) + " | overall short | medium | long | ranked first |"
    print(header)
    print("|" + "---|" * (len(FIELDS) + 5))
    for model in sorted(scores):
        s = scores[model]

        def mean(field: str) -> str:
            values = s.get(field, [])
            if not values:
                return "-"
            sd = statistics.stdev(values) if len(values) > 1 else 0
            return f"{statistics.mean(values):.1f} ± {sd:.1f}"
        print(f"| {model} | " + " | ".join(mean(f) for f in FIELDS) +
              f" | {mean('overall:short')} | {mean('overall:medium')} | {mean('overall:long')} | {firsts[model]} |")
    print()
    for model in sorted(errors):
        print(f"## {model}: {len(errors[model])} errors")
        for error in errors[model]:
            print(f"- {error}")
        print()


if __name__ == "__main__":
    main()
