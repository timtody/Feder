#!/bin/zsh
# Runs the six bench configurations in parallel; logs and results-*.json land in ane/ and cpuonly/.
B=/Users/julius.taylor/projects/recorder/build/qa/sortformer
cd $B/ane
$B/sfbench-ane sortformer clean 3 > sortformer-clean.log 2>&1 &
$B/sfbench-ane sortformer -55 3 > sortformer-55.log 2>&1 &
$B/sfbench-ane lseend clean 3 > lseend-clean.log 2>&1 &
$B/sfbench-ane lseend -55 3 > lseend-55.log 2>&1 &
cd $B/cpuonly
$B/sfbench-cpuonly sortformer clean 3 > sortformer-clean.log 2>&1 &
$B/sfbench-cpuonly sortformer -55 3 > sortformer-55.log 2>&1 &
wait
echo ALLDONE
