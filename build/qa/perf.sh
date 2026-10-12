#!/bin/zsh
# perf.sh <name>: builds for the iPhone 17 simulator, then runs the trace test while capturing the app's Interaction log.
cd /Users/julius.taylor/projects/recorder
name=$1; udid=69C35674-CE05-437A-B1F2-C37D41BE149B; dir=build/qa/perf; mkdir -p $dir
xcodebuild build-for-testing -project Recorder.xcodeproj -scheme Recorder -destination "id=$udid" -derivedDataPath build/DerivedDataSwipe CODE_SIGNING_ALLOWED=NO > $dir/$name-build.log 2>&1 || { echo "BUILD FAILED"; grep -E "error:" $dir/$name-build.log | head; exit 1; }
xcrun simctl spawn $udid log stream --style compact --predicate 'subsystem == "de.timtody.feder" AND category == "Interaction"' > $dir/$name-trace.log 2>&1 &
logpid=$!
sleep 2
for run in 1 2; do
  xcodebuild test-without-building -project Recorder.xcodeproj -scheme Recorder -destination "id=$udid" -derivedDataPath build/DerivedDataSwipe -only-testing:ScribeUITests/ResponsivenessTests/testInteractionPathsTrace > $dir/$name-test$run.log 2>&1
  echo "run $run exit=$?"
  echo "===== run $run done" >> $dir/$name-trace.log
done
sleep 1; kill $logpid
grep -E "Test Case.*(passed|failed)" $dir/$name-test*.log | sed 's/^.*Test Case/Test Case/'
grep -E "turn|frame|=====" $dir/$name-trace.log | sed -E 's/^.*Interaction\] //'
