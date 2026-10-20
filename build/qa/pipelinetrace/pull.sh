#!/bin/zsh
# Pipeline Trace on the Mac (FED-195): copies Feder's traces (Library/Caches/PipelineTraces) from the connected iPhone
# with devicectl, writes the HTML pages (view.py) and opens the overview. Everything stays on this Mac (traces/, html/,
# both ignored by git). A Debug build of Feder or Feder Lab must be installed; the iPhone unlocked and trusted.
#   build/qa/pipelinetrace/pull.sh            the first connected iPhone
#   build/qa/pipelinetrace/pull.sh <device>   a given one (name or identifier, as `xcrun devicectl list devices` shows)
#   build/qa/pipelinetrace/pull.sh --local <dir>   no iPhone: render traces already on disk (AirDropped JSON files)
set -e
here="${0:A:h}"
traces="$here/traces"
mkdir -p "$traces"
if [[ "$1" == "--local" ]]; then
  traces="${2:?a folder with trace .json files}"
else
  device="$1"
  if [[ -z "$device" ]]; then
    list=$(mktemp)
    xcrun devicectl list devices --json-output "$list" > /dev/null
    device=$(python3 -I -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
# Real iPhones only (simulators are listed too, transport "sameMachine"); a connected one first, else one on this
# Wi-Fi that devicectl can reach on demand ("disconnected"), never one that is "unavailable".
phones = [d for d in devices if d.get("hardwareProperties", {}).get("platform") == "iOS"
          and d.get("connectionProperties", {}).get("transportType") != "sameMachine"
          and d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
print(phones[0]["identifier"] if phones else "")' "$list")
    rm -f "$list"
    [[ -n "$device" ]] || { echo "No connected iPhone (xcrun devicectl list devices). Or: pull.sh --local <folder>"; exit 1; }
  fi
  echo "Copying traces from $device …"
  if ! xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
      --domain-identifier de.timtody.feder --source Library/Caches/PipelineTraces --destination "$traces" > /dev/null 2>&1; then
    echo "No traces on the iPhone: install a Debug build of Feder or Feder Lab with Pipeline Trace (FED-195),"
    echo "record or import something, wait until its summary is written, then run this again."
    [[ -n "$(ls "$traces" 2>/dev/null)" ]] || exit 1
    echo "Showing the traces copied before."
  fi
fi
python3 -I "$here/view.py" "$traces" "$here/html"
open "$here/html/index.html"
