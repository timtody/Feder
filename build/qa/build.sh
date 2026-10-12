#!/bin/zsh
# Build gate: Debug build for the generic iOS Simulator; prints app-code errors/warnings and the result line.
cd /Users/julius.taylor/projects/recorder || exit 1
OUT=$(xcodebuild -project Recorder.xcodeproj -scheme Recorder -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1)
st=$?
echo "$OUT" | grep -E "error:|warning:" | grep -E "/recorder/(Recorder|ScribeUITests|FederWidgets|Shared)/|error:" | grep -v "appintentsmetadataprocessor" | sort -u
echo "$OUT" | grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*"
exit $st
