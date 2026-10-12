#!/bin/zsh
# profile.sh <name>: rebuilds for the iPhone 17 simulator, runs the trace test and records a Time Profiler of the app meanwhile.
cd /Users/julius.taylor/projects/recorder
name=$1; udid=69C35674-CE05-437A-B1F2-C37D41BE149B; dir=build/qa/perf
if [[ "$2" != "nobuild" ]]; then
  xcodebuild build-for-testing -project Recorder.xcodeproj -scheme Recorder -destination "id=$udid" -derivedDataPath build/DerivedDataSwipe CODE_SIGNING_ALLOWED=NO > $dir/$name-build.log 2>&1 || { echo BUILD FAILED; exit 1; }
fi
xcodebuild test-without-building -project Recorder.xcodeproj -scheme Recorder -destination "id=$udid" -derivedDataPath build/DerivedDataSwipe -only-testing:ScribeUITests/ResponsivenessTests/testInteractionPathsTrace > $dir/$name-test.log 2>&1 &
testpid=$!
pid=""
for i in {1..120}; do pid=$(pgrep -f "$udid/data/Containers/Bundle/Application/.*/Feder.app/Feder" | head -1); [[ -n "$pid" ]] && break; sleep 0.5; done
sleep 4                                   # XCUITest relaunches the app once for its session: take the pid that stays
pid=$(pgrep -f "$udid/data/Containers/Bundle/Application/.*/Feder.app/Feder" | head -1)
echo "app pid $pid"
rm -rf $dir/$name.trace
for attempt in 1 2 3; do
  xcrun xctrace record --template 'Time Profiler' --device $udid --attach $pid --time-limit 70s --output $dir/$name.trace > $dir/$name-xctrace.log 2>&1 && break
  sleep 2; pid=$(pgrep -f "$udid/data/Containers/Bundle/Application/.*/Feder.app/Feder" | head -1); echo "retry with pid $pid"
done
wait $testpid
grep -E "Test Case.*(passed|failed)" $dir/$name-test.log | sed 's/^.*Test Case/Test Case/'
python3 $dir/tp4.py $dir/$name.trace 14 > $dir/$name-perpress.txt 2>&1
echo done
