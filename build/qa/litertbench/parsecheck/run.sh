#!/bin/zsh
# FED-151: the summary parser on canned answers (main.swift), on the Mac, without Xcode or a model.
#   build/qa/litertbench/parsecheck/run.sh                  the cases; exits 1 when one comes out wrong
#   build/qa/litertbench/parsecheck/run.sh results/*.txt    every raw answer of LiteRTBench output, as stored now
# SOURCE=<file> compiles another copy of TranscriptTitler.swift instead (an older commit's, to compare).
set -e
here=${0:A:h}
source=${SOURCE:-$here/../../../../Recorder/Services/TranscriptTitler.swift}
dir=$(mktemp -d); trap "rm -rf $dir" EXIT
swiftc -default-isolation MainActor -enable-bare-slash-regex "$source" "$here/main.swift" -o $dir/parsecheck
$dir/parsecheck "$@"
