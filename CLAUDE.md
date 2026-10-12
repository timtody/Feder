# Feder — notes for Claude

Feder is a local-only iPhone transcription app: SwiftUI, Swift 6, iOS 26+, built with Xcode 27 / iOS 27 SDK. It does live transcription, speaker identification, people, tags, search and on-device summaries. The README is the detailed reference for architecture, measurements and every design decision. Read the section you are touching before changing it, and keep it in sync afterwards (Look, Search, UI tests and the file list in particular). Open work and the roadmap are issues in Linear (see Planning in Linear).

## Hard rules

- **Never change the bundle id (`de.timtody.feder`) or `PRODUCT_NAME` (`Feder`).** The user's real transcripts live on their iPhone under this identity, and the App Store record is tied to it. (Changed once, on 2026-10-08, from `de.cofinpro.recorder` / `Recorder` before the first App Store submission, at the user's request: it publishes under timtody; the transcripts under the old identity were deliberately not moved.)
- **Nothing leaves the phone.** Do not add network calls except the existing, user-initiated model downloads: Parakeet, Nemotron, the live-label models (LS-EEND; Sortformer only in Debug builds) and Gemma via pinned Hugging Face revisions. No analytics and no cloud models.
- **UI tests and the `-seedSamples` launch hooks are simulator only.** They must never touch an iPhone's store.
- **Keep `CHANGELOG.md` current.** Every change a user would notice gets a line under the version in progress, in English and German, written for users (what they can do now, not how it is built); fixes the user never saw (inside one unreleased version) need none.
- **Git, with GitHub as the remote** (`origin`: `timtody/Feder`). Commit after each step with a clear message, so steps can be reverted; still look before you overwrite or delete. `build/`, DerivedData and `*.xcresult` are ignored, so nothing under `build/` reaches GitHub (the `build/qa/` scripts included: FED-61).

## Planning in Linear

- **The roadmap, open tasks, device checks and product decisions are issues in Linear** (workspace outerspace, team Feder, `FED`), reached through the `linear` MCP server. `ROADMAP.md` and `TASKS.md` only point there; don't add items to them. If the Linear tools are missing (not connected or logged out), say so and ask the user to run `/mcp`; don't fall back to the markdown files.
- **Work starts from an issue.** Read it before starting; when the user asks for work that has none, create it in the matching project. A commit that belongs to an issue ends its subject with the id, e.g. `… (FED-12)`.
- **The user follows the project through Linear, not the code.** When a session ends with commits, comment on its issue in plain language: *What changed* (for someone using the app), *How it works* (a few sentences, at most three `path:line` places), *Verified*, *Open* (as new linked issues), and the commit hashes; then set it to Done or leave it In Progress. Anything left open (a check only the iPhone can do, a follow-up, a known gap, a measurement still to take) becomes a new issue in the matching project, not a note in a file. Measurements and design reasons still go into the README.
- **Keep the team's documents current** (Linear › Feder): when the shape of the app changes (a new screen, a step after Stop, a model, a concurrency domain), update *Start here: how Feder works*; a new promise or rule goes into *Product rules*; a new script or command into *Build, run and test*. `/catch-up` (`.claude/skills/catch-up/`) explains the changes since the user last looked.
- **Labels:** `Feature`, `Improvement` or `Bug`; `Device-only` for what only a real iPhone can check; `Differentiator`, `P3` or `Moonshot` for roadmap ideas; `Decision` for product decisions. Releases are projects (`Feder 1.2`). Where a feature touches the network, iCloud or another app, its issue says so, since that is a product decision.
- **Create and update issues freely; ask before deleting** or archiving issues and projects, or regrouping them.

## Build & test

```sh
xcodegen generate          # after editing project.yml, or adding/removing files in ScribeUITests/, Shared/ or FederWidgets/ (Recorder/ is a synced folder)
build/qa/build.sh          # build gate: Debug, generic iOS Simulator; prints app errors/warnings + BUILD SUCCEEDED/FAILED
```

- **UI tests (XCUITest, `ScribeUITests/`).** Test on **iOS 27 only** unless the user asks for 26.5. Use the iOS 27 test simulator `3DAF994D-A851-4F3E-9AF3-4755207A00D1` with derived data `build/DerivedDataUITests`. It has a hardware keyboard connected, so the software keyboard sits off-screen.
- **Skip the slow hit-area test (~7 min) in intermediate runs:** `-skip-testing:ScribeUITests/SpeakerNamingTests/testNameRowHitArea`. Run the full suite only for the final check.
- **`build/qa/uitests.sh` runs iOS 27 and 26.5 sequentially (~25 min).** Use it only when both runtimes are wanted.
- **Visual checks:** use the iPhone 17 iOS 27 simulator `69C35674-CE05-437A-B1F2-C37D41BE149B` (derived data `build/DerivedDataSwipe`). It matches the user's device and has many transcripts, so lists scroll and the tab bar minimizes.
- **One `xcodebuild` per simulator at a time.** Parallel runs on the same simulator interrupt each other.
- **Run long `xcodebuild test` runs in the background and poll the log.** A foreground command dies after 10 minutes. xcodebuild sometimes lingers after the last test has finished; kill it once the log shows the final suite line.
- **Microphone for recording tests:** grant it first with `xcrun simctl privacy <udid> grant microphone de.timtody.feder`.
- **Responsiveness:** `build/qa/perf.sh <name>` builds for the iPhone 17 simulator, runs `ResponsivenessTests/testInteractionPathsTrace` twice and captures the app's `-interactionTrace` log (a press's main-thread turn and first frame); `build/qa/perf/profile.sh <name> [nobuild]` records a Time Profiler of that test and `tp4.py` aggregates it per press (symbolicated with `atos` against `Feder.debug.dylib`). Numbers and method: README › Performance.
- **Launching the app by hand:** `xcrun simctl launch` with the DEBUG hooks (`-seedSamples`, `-search <text>`, `-searchToken person:<name>,tag:<tag>`, `-openFirstTranscript`, `-autoRecord -autoStopAfter <s>`, `-fakePrepareSeconds <s>`, `-fakeWordChanges`, `-interactionTrace`, …; see README › Build). The hooks live in `MainView+LaunchArguments.swift`. In zsh, quote or `eval` multi-word arguments, because `$args` is not word-split.
- **Animations:** `xcrun simctl io <udid> recordVideo --codec h264 --force <file>`. The recordings have a variable frame rate, so extract frames with `ffmpeg -fps_mode vfr`. Inspect screenshots and frames yourself before claiming something looks right.
- **Scratch files** go under `build/qa/` (not committed anywhere) and get cleaned up afterwards.

## Working with this user

- **Language:** the user writes German and English; answer in the language of their message.
- **Match the native apps exactly:** Apple Music (tab bar, mini player → Now Playing) and Voice Memos (list, swipe pills), using Liquid Glass best practice. The transcript card closes with a glass back button at the top left or a swipe to the right from the left edge (UIKit's back gesture); swiping down only scrolls. Prefer system components (TabView, `tabViewBottomAccessory`, swipe actions, toolbars, zoom transitions) over custom re-implementations; the user rejects custom versions of things iOS can draw.
- **Before saying "iOS can't do that", probe it.** Many looks depend on parameters: for example, swipe actions render as wide pills with the title below only for rows of roughly 62–70 pt. When a public API really can't do it, say so plainly, give the options, and recommend one.
- **Read requests literally and narrowly.** "Remove the heading while searching" does not mean "remove it everywhere". When scope is ambiguous, ask, or pick the narrower reading and say so.
- **Verify before reporting.** Build, run the relevant tests, and look at screenshots or video frames. Report failures honestly, and keep the final report short: what changed, what was verified, what is open.

## Code conventions

- **Concurrency:** Swift 6 strict concurrency with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Mark pure helpers and layouts `nonisolated`. Anything SwiftUI might evaluate off the main thread (for example `ViewThatFits` candidates on iOS 26) must not capture main-actor closures; this caused a crash once. Audio hardware calls (AVAudioSession, AVAudioEngine) run on the `AudioHardware` global actor, never on the main actor. Off-main work must be `@concurrent`: a plain `nonisolated async` runs on its caller's actor here. The concurrency domains are listed in README › Architecture.
- **Every press answers in its frame:** no synchronous SwiftData fetches, file I/O, model loading or audio calls in a button action or a `body`; slow things run off the main actor and the view shows a placeholder meanwhile. Measure with `-interactionTrace` before claiming an improvement.
- **Comments say *why*:** measurements, the iOS behaviour being worked around, rejected alternatives. Match the existing density and tone.
- **UI strings are English in code, with German in `Recorder/Localizable.xcstrings`.** The app follows the iPhone's language. A literal in `Text`/`Button`/`Label` is extracted by the compiler; a string built at runtime (a `String` handed to a view, an error, a status) needs `String(localized:)`. Add the German translation to the catalog with every new string (Xcode does it when the project is built in the IDE; from the command line add it to the JSON). Names the app stores ("New Transcript 3") are written in the language of the moment, so code that recognizes them must accept both.
- **SwiftData:** model changes must be additive with defaults (lightweight migration). Never require a destructive migration of the user's store.
- **Pin dependencies exactly in `project.yml`:** FluidAudio, mlx-swift-lm, mlx-swift, swift-transformers. MLX needs Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
