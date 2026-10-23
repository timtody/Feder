prewarmbench (FED-212): what prewarming Parakeet saves after Stop, by recording length (M5 Mac).
run.sh builds, makes 60 minutes of DiarBench meeting audio and its cuts (audio/), and measures each length in fresh
processes: Parakeet cold (its Core ML cache deleted first) and warm, Nemotron's diarization; out/results.jsonl.
report.py prints the table. Results are in the README (After Stop: words, speakers, vocabulary).
