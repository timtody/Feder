#!/bin/zsh
cd /Users/julius.taylor/projects/recorder
for pair in "27:3DAF994D-A851-4F3E-9AF3-4755207A00D1" "26:78B9E995-6067-498E-B711-1F3EF11A816C"; do
  name=${pair%%:*}; id=${pair#*:}
  # iOS's one-time editing-gestures tutorial counts as shown: on a simulator without this key (a new one) the first
  # shake's Undo never reached Feder's UndoManager (README › UI tests).
  xcrun simctl bootstatus $id -b > /dev/null                 # spawn needs it booted (xcodebuild would boot it anyway)
  xcrun simctl spawn $id defaults write com.apple.keyboard.preferences KeyboardDidShowProductivityTutorial -bool true
  rm -rf build/qa/full$name.xcresult
  xcodebuild test -project Recorder.xcodeproj -scheme Recorder -destination "id=$id" -derivedDataPath build/DerivedDataUITests \
    -resultBundlePath build/qa/full$name.xcresult > build/qa/full$name.log 2>&1
  echo "ios$name exit=$?"
  grep -E "error:|' failed|Executed [0-9]+ tests" build/qa/full$name.log | sed 's/^.*Test Case/Test Case/' | tail -6
done
