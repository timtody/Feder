"""ASR bench on the Mac (FED-198): one model over a clip set through mlx-audio, its text per clip into out/<run>.json.

  .venv/bin/python bench.py <run> <model> [--set mls|synth] [--att 56,13] [--hotwords short|builtin]
                                          [--language de-DE|German] [--limit n] [--streamed]

Models are mlx-audio's (Qwen3-ASR, Nemotron 3.5 ASR Streaming), downloaded by mlx-audio into ~/.cache/huggingface on
the Mac; the revision used is written into the result. Clip sets are vocabbench's: mls (DiarBench's 192 real German
MLS clips) and synth (208 synthetic sentences with the vocabulary's terms, two Eloquence voices). score.py scores them.
"""
import argparse, json, os, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
VOCAB = Path(os.environ.get("VOCABBENCH", "/Users/julius.taylor/projects/recorder/.claude/worktrees/night-2026-10-18/build/qa/vocabbench"))


def clips(name):
    data = json.load(open(VOCAB / "clips" / f"{name}.json"))
    out = []
    for clip in data["clips"]:
        wav = Path(clip["wav"])
        if name == "synth":                      # the json was written in another worktree; the audio is beside it
            wav = VOCAB / "clips" / "synth" / clip["voice"] / wav.name
        out.append({**clip, "wav": str(wav)})
    return data, out


def revision(repo):
    snaps = Path.home() / ".cache/huggingface/hub" / f"models--{repo.replace('/', '--')}" / "refs" / "main"
    return snaps.read_text().strip() if snaps.exists() else None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("run"); p.add_argument("model")
    p.add_argument("--set", default="mls"); p.add_argument("--att"); p.add_argument("--hotwords")
    p.add_argument("--language"); p.add_argument("--limit", type=int)
    p.add_argument("--streamed", action="store_true")
    a = p.parse_args()

    from mlx_audio.stt import load
    import soundfile
    data, items = clips(a.set)
    items = items[: a.limit] if a.limit else items
    nemotron = "nemotron" in a.model.lower()
    language = a.language or ("de-DE" if nemotron else "German")
    kwargs = {"language": language}
    if nemotron and not a.streamed:
        # The whole clip at once instead of 30 s pieces. mlx-audio's decode still encodes it chunk by chunk with the
        # caches (stream_encode, one call per right_context + 1 frames: per 80 ms frame at [56,0], hence ~1.2x real
        # time there against ~9x at [56,13]); the text matched --streamed on 4 clips at both.
        kwargs["chunk_duration"] = None
    if a.att:
        kwargs["att_context_size"] = [int(x) for x in a.att.split(",")]
    if a.hotwords:
        kwargs["hotwords"] = data[a.hotwords] if a.hotwords in data else json.load(open(a.hotwords))

    t = time.time()
    model = load(a.model)
    load_s = time.time() - t
    model.generate(items[0]["wav"], **kwargs)    # warm-up: compiled kernels, caches

    results, audio_s, wall_s = [], 0.0, 0.0
    for i, clip in enumerate(items):
        seconds = soundfile.info(clip["wav"]).duration
        t = time.time()
        text = model.generate(clip["wav"], **kwargs).text.strip()
        took = time.time() - t
        audio_s += seconds; wall_s += took
        results.append({"id": clip["id"], "voice": clip.get("voice"), "kind": clip.get("kind"), "ref": clip["text"],
                        "hyp": text, "audio": seconds, "wall": took})
        if i % 20 == 0:
            print(f"{i + 1}/{len(items)}  {audio_s / wall_s:.1f}x  {text[:90]}", flush=True)

    out = {"run": a.run, "model": a.model, "revision": revision(a.model), "set": a.set, "args": vars(a),
           "kwargs": {k: v for k, v in kwargs.items() if k != "hotwords"}, "hotwords": kwargs.get("hotwords"),
           "load_s": load_s, "audio_s": audio_s, "wall_s": wall_s, "clips": results}
    (HERE / "out").mkdir(exist_ok=True)
    json.dump(out, open(HERE / "out" / f"{a.run}.json", "w"), ensure_ascii=False, indent=1)
    print(f"{a.run}: {len(results)} clips, {audio_s / 60:.1f} min audio in {wall_s:.0f} s ({audio_s / wall_s:.1f}x real time)")


if __name__ == "__main__":
    main()
