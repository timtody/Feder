#!/bin/zsh
cd /Users/julius.taylor/projects/recorder
for pair in "27:3DAF994D-A851-4F3E-9AF3-4755207A00D1" "26:78B9E995-6067-498E-B711-1F3EF11A816C"; do
  name=${pair%%:*}; id=${pair#*:}
  rm -rf build/qa/full$name.xcresult
  xcodebuild test -project Recorder.xcodeproj -scheme Recorder -destination "id=$id" -derivedDataPath build/DerivedDataUITests \
    -resultBundlePath build/qa/full$name.xcresult > build/qa/full$name.log 2>&1
  echo "ios$name exit=$?"
  grep -E "error:|' failed|Executed [0-9]+ tests" build/qa/full$name.log | sed 's/^.*Test Case/Test Case/' | tail -6
done
