#!/bin/zsh
# Review re-run: five waves, each one Sortformer (Neural Engine) and one LS-EEND run at 3x, so at most one process uses
# the Neural Engine; noise seeds 55, 1, 2, 3. Then Sortformer CPU only (clean, the author's cpuonly binary) alone, then
# throughput at 200x on m03 alone. Every run in its own directory with its log, results and snapshot dumps.
B=/Users/julius.taylor/projects/recorder/build/qa/sortformer
BIN=$B/.build/release/sfbench
R=$B/fix/runs
mkdir -p $R
run() {   # dir model cond seed speed [filter] [binary]
  local d=$R/$1; mkdir -p $d; cd $d
  SEED=$4 ${7:-$BIN} $2 $3 $5 $6 > run.log 2>&1
  echo "$(date +%T) done $1" >> $R/progress.log
}
echo "$(date +%T) start" > $R/progress.log
for wave in "clean 55 clean" "-55 55 n55" "-55 1 n1" "-55 2 n2" "-55 3 n3"; do
  set -- ${=wave}
  run sortformer-$3 sortformer $1 $2 3 "" &
  run lseend-$3 lseend $1 $2 3 "" &
  wait
done
run cpuonly-clean sortformer clean 55 3 "" $B/sfbench-cpuonly
run thru-sortformer-m03 sortformer clean 55 200 m03
run thru-lseend-m03 lseend clean 55 200 m03
run thru-cpuonly-m03 sortformer clean 55 200 m03 $B/sfbench-cpuonly
echo "$(date +%T) ALLDONE" >> $R/progress.log
