#!/bin/zsh
# The whole UI test suite: iOS 27 and 26.5 (`uitests.sh 27` or `uitests.sh 26`: one runtime). Built once for testing, then
# each runtime in 4 parallel clones of its simulator (classes are handed out whole, so the long ones are split:
# CalendarTests / CalendarSettingsTests, SpeakerNamingTests / NameRowHitAreaTests). No diagnostics are collected after a
# failure: that took 10 minutes per failing run ("Failure collecting diagnostics from simulator: Timed out after 600 s").
cd /Users/julius.taylor/projects/recorder
runtimes=("27:3DAF994D-A851-4F3E-9AF3-4755207A00D1" "26:78B9E995-6067-498E-B711-1F3EF11A816C")
[[ -n $1 ]] && runtimes=(${(M)runtimes:#$1:*})
first=${runtimes[1]#*:}
xcodebuild build-for-testing -project Recorder.xcodeproj -scheme Recorder -destination "id=$first" \
  -derivedDataPath build/DerivedDataUITests > build/qa/build-for-testing.log 2>&1 || { echo "build failed"; tail -20 build/qa/build-for-testing.log; exit 1; }
for pair in $runtimes; do
  name=${pair%%:*}; id=${pair#*:}
  # iOS's one-time editing-gestures tutorial counts as shown: on a simulator without this key (a new one) the first
  # shake's Undo never reached Feder's UndoManager (README › UI tests). Its clones inherit it.
  xcrun simctl bootstatus $id -b > /dev/null                 # spawn needs it booted (xcodebuild would boot it anyway)
  xcrun simctl spawn $id defaults write com.apple.keyboard.preferences KeyboardDidShowProductivityTutorial -bool true
  rm -rf build/qa/full$name.xcresult
  xcodebuild test-without-building -project Recorder.xcodeproj -scheme Recorder -destination "id=$id" \
    -derivedDataPath build/DerivedDataUITests -resultBundlePath build/qa/full$name.xcresult \
    -parallel-testing-enabled YES -parallel-testing-worker-count 4 -collect-test-diagnostics never \
    > build/qa/full$name.log 2>&1
  echo "ios$name exit=$?"
  xcrun xcresulttool get test-results summary --path build/qa/full$name.xcresult 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
minutes = (d["finishTime"] - d["startTime"]) / 60
print(d["result"], "passed", d["passedTests"], "failed", d["failedTests"], "skipped", d["skippedTests"],
      "%.1f min" % minutes)
for f in d.get("testFailures", []): print("  FAIL", f["testIdentifierString"], "-", f["failureText"][:200])'
done
