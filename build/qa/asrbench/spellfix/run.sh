#!/bin/zsh
# Builds the harness around the app's Recorder/Models/VocabularySpelling.swift and runs it: in.json is a result file
# in asrbench / FederLab format ({"clips": [{id, ref, hyp, kind, voice}]}), out.json the same with hyp fixed.
set -e
here=${0:A:h}
cp $here/../../../../Recorder/Models/VocabularySpelling.swift $here/Sources/spellfix/VocabularySpelling.swift
swift build -c release --package-path $here 2>&1 | grep -E "error|warning: var|BUILD" || true
$here/.build/release/spellfix "$@"
