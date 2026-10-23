#!/bin/zsh
# FED-212: Parakeet cold vs warm (prewarmed) and Nemotron, by recording length, each measurement in its own process.
# Cold = this tool's own Core ML cache deleted first (~/Library/Caches/prewarmbench/com.apple.e5rt.e5bundlecache), as
# the first recording after an update; warm = the cache kept, as after the prewarm. Writes out/results.jsonl.
set -e
here=${0:A:h}
cd $here
swift build -c release 2>&1 | grep -E "error|Compiling|Build" | tail -1
bin=$here/.build/release/prewarmbench
cache=~/Library/Caches/prewarmbench/com.apple.e5rt.e5bundlecache
mkdir -p audio out
# 60 minutes of real German meeting audio: the twelve DiarBench meetings (3 min each) twice.
if [[ ! -f audio/long.wav ]]; then
  (for f in ../../diarbench/meet/m*.wav ../../diarbench/meet/m*.wav; do echo "file '${f:A}'"; done) > audio/list.txt
  ffmpeg -loglevel error -y -f concat -safe 0 -i audio/list.txt -ar 16000 -ac 1 -c:a pcm_s16le audio/long.wav
fi
if (( $# )); then lengths=($@); else lengths=(0.25 0.5 1 2 5 10 18 30 60); fi
for minutes in $lengths; do
  f=audio/len-$minutes.wav
  [[ -f $f ]] || ffmpeg -loglevel error -y -i audio/long.wav -t $(( minutes * 60 )) -c copy $f
  $bin speakers $f | sed "s/^/{\"minutes\":$minutes,\"case\":\"speakers\",\"r\":/;s/$/}/" >> out/results.jsonl
  for rep in 1 2; do
    rm -rf $cache
    $bin words $f | sed "s/^/{\"minutes\":$minutes,\"case\":\"cold\",\"r\":/;s/$/}/" >> out/results.jsonl
    $bin words $f | sed "s/^/{\"minutes\":$minutes,\"case\":\"warm\",\"r\":/;s/$/}/" >> out/results.jsonl
  done
  echo "$minutes min done"
done
