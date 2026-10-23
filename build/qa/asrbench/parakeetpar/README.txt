parakeetpar (FED-212): does more parallelism make Parakeet Ultra's words step faster?

Audio: six DiarBench meetings (real German speech) joined into one 18-minute file, 16 kHz mono:
  ls ../../diarbench/meet/m0[0-5]*.wav | sed "s|^|file '$PWD/|;s|$|'|" > audio/list.txt
  ffmpeg -f concat -safe 0 -i audio/list.txt -ar 16000 -ac 1 -c:a pcm_s16le audio/meeting18.wav
Run:  swift build -c release && .build/release/parakeetpar audio/meeting18.wav
Results are in the README (After Stop: words, speakers, vocabulary).
