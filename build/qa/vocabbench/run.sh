#!/bin/zsh
# Vocabulary bench (FED-56): builds the bench with the app's own VocabularyMerge, Vocabulary and word parsing, makes the
# clips if they are missing, and scores the synthetic set and the real MLS clips. Reports go to out/report-*.txt.
#   run.sh [--names] [--short] [--parakeet] [--fresh]
#     --names     people's names in the contextual strings (FED-55)
#     --short     a short list (the 35 terms the sentences use) instead of Vocabulary.builtIn, like a user's own words
#     --parakeet  Parakeet Ultra's words as the base instead of SpeechTranscriber's (the app when Parakeet is chosen);
#                 builds bench/parakeet.swift against FluidAudio (FLUIDAUDIO=<checkout>, default: the app's pinned
#                 checkout in the main checkout's build/DerivedDataSwipe, only read: built from a copy) and needs the
#                 model downloaded
#     --fresh     re-run the recognizers instead of reading their cached output (out/base*, out/hinted-*)
set -e
setopt pipefail            # a bench that exits 2 (assets missing) must fail the run, not vanish into tee
here=${0:A:h}
repo=${here:h:h:h}
main=$(git -C $repo rev-parse --path-format=absolute --git-common-dir); main=${main:h}   # the main checkout (worktrees)
utt=${UTT:-$repo/build/qa/diarbench/utt}   # DiarBench's MLS clips (local data, prep.py)
[[ -d $utt || -n $UTT ]] || utt=$main/build/qa/diarbench/utt
mkdir -p $here/.build/gen $here/out

# The app's word parsing (SpeechTranscriberEngine is a main-actor class with live-recording state, so only its pure
# static parsers are taken) and TranscriptWord, cut from the app's sources so the bench never drifts from them.
transcriptWord=$(awk '/^nonisolated struct TranscriptWord/,/^}$/' $repo/Recorder/Models/Recording.swift)
{
  print "import Foundation\nimport CoreMedia\nimport Speech\n\nnonisolated enum SpeechTranscriberEngine {"
  awk '/nonisolated static func words\(from text: AttributedString/{p=1} p{print} p && /private static func isPunctuation/{q=1} q && /^    }$/{exit}' \
    $repo/Recorder/Services/SpeechTranscriberEngine.swift
  print "}\n"
  print -r -- $transcriptWord
} > $here/.build/gen/AppParts.swift

swiftc -O -swift-version 6 -default-isolation MainActor -o $here/.build/vocabbench \
  $repo/Recorder/Models/VocabularyMerge.swift $repo/Recorder/Models/Vocabulary.swift \
  $here/.build/gen/AppParts.swift $here/bench/main.swift

# gen.py reads a clip again only when it is missing or its sentence or voice changed (and then drops its cached
# passes if the audio differs), so the manifests are always rewritten.
python3 $here/gen.py synth
[[ ! -d $utt ]] || python3 $here/gen.py mls $utt

fresh=(); [[ " $* " == *" --fresh "* ]] && fresh=(--fresh)
if [[ " $* " == *" --parakeet "* ]]; then
  fluid=${FLUIDAUDIO:-$main/build/DerivedDataSwipe/SourcePackages/checkouts/FluidAudio}
  pinned=$(awk '/^  FluidAudio:/{p=1} p && /exactVersion:/{print $2; exit}' $repo/project.yml)
  # --no-optional-locks: a plain git call refreshes the checkout's index, and the default checkout is the main
  # checkout's, which the bench must only read. SwiftPM builds a copy without .git, for the same reason.
  [[ $(git --no-optional-locks -C $fluid describe --tags 2>/dev/null) == "v$pinned" ]] \
    || { echo "FluidAudio at $fluid is not the app's pinned $pinned (FLUIDAUDIO=<checkout>)"; exit 2; }
  pkg=$here/.build/parakeet
  mkdir -p $pkg/Sources/parakeet
  rsync -a --delete --exclude .git $fluid/ $pkg/FluidAudio/
  cat > $pkg/Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "parakeet",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "FluidAudio")],
    targets: [.executableTarget(name: "parakeet", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.defaultIsolation(MainActor.self)])]
)
EOF
  cp $here/bench/parakeet.swift $pkg/Sources/parakeet/main.swift
  {
    print "import Foundation\nimport FluidAudio\n\nenum ParakeetTranscriber {"
    awk '/nonisolated static func words\(from tokens: \[TokenTiming\]\)/{p=1} p{print} p && /^    }$/{exit}' \
      $repo/Recorder/Services/ParakeetTranscriber.swift
    print "}\n"
    print -r -- $transcriptWord
  } > $pkg/Sources/parakeet/AppParts.swift
  swift build -c release --package-path $pkg > $pkg/build.log 2>&1 || { tail -30 $pkg/build.log; exit 1; }
  for set in synth mls; do
    [[ -f $here/clips/$set.json ]] && $pkg/.build/release/parakeet $here/clips/$set.json $here/out $fresh
  done
fi

variant=builtin
[[ " $* " == *" --short "* ]] && variant=short
[[ " $* " == *" --names "* ]] && variant=$variant+names
[[ " $* " == *" --parakeet "* ]] && variant=$variant-parakeet
for set in synth mls; do
  [[ -f $here/clips/$set.json ]] || { echo "no clips/$set.json, skipped"; continue; }
  $here/.build/vocabbench $here/clips/$set.json $here/out "$@" | tee $here/out/report-$set-$variant.txt
done
