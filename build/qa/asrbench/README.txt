ASR bench on the Mac (FED-198): models Feder doesn't ship, through mlx-audio, on vocabbench's clip sets.
  uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python mlx-audio soundfile    (mlx-audio 0.6.1)
  ./run.sh                    every run, one after the other (skips runs whose out/<run>.json exists)
  .venv/bin/python bench.py <run> <model> [--set mls|synth] [--att 56,13] [--hotwords short] [--limit n]
  python3 score.py [run…]     MLS word errors (nemotronlive's scorer; vocabbench's cached Apple and Parakeet passes
                              alongside as a check: 7.4 % and 5.3 %), made-up text, synth term accuracy
builtin.json: Feder's Vocabulary.builtIn (112 = the 35 terms the sentences say + 77 distractors), for --hotwords
builtin.json and for counting false terms.
Clips: VOCABBENCH=<vocabbench dir> (default the night-2026-10-18 worktree's, which has the synth audio). Models land in
~/.cache/huggingface on the Mac; each result keeps the revision. Results stay local (out/).
