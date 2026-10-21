#!/bin/zsh
# FED-198: every run of the Mac ASR bench, one after the other (speed numbers need the Mac to themselves).
cd "${0:A:h}"
# A run already going (started before): wait for it.
while pgrep -qf "python bench.py"; do sleep 5; done
Q=mlx-community/Qwen3-ASR-1.7B; N=mlx-community/nemotron-3.5-asr-streaming-0.6b
run() { [[ -f out/$1.json ]] && { echo "have $1"; return }; .venv/bin/python bench.py "$@" 2>&1 | grep -v "Fetching\|Warning" | tail -1 }
run qwen17-8bit $Q-8bit
run nem-56-13 $N --att 56,13
run qwen17-4bit $Q-4bit
run qwen06-8bit mlx-community/Qwen3-ASR-0.6B-8bit
run nem-56-6 $N --att 56,6
run synth-qwen17-8bit $Q-8bit --set synth
run synth-qwen17-8bit-short $Q-8bit --set synth --hotwords short
run synth-nem-56-13 $N --set synth --att 56,13
# 80 ms lookahead runs at ~1.2x on the Mac (one encoder step per frame): 40 clips, only to check MLX against
# FluidAudio's Core ML build on the same clips (nemotronlive wer <clips> 40).
run nem-56-0-40 $N --att 56,0 --limit 40
echo ALL DONE
