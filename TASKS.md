# Open tasks

Known gaps left over from the recent work, most important first. Remove an item once it is done.

## Verify on the real device

- [ ] **Try it on the iPhone 17.** Everything since the one-card redesign has been checked only in the simulator. That covers the Stop → toolbar melt, the timer flight, and the start time and place on the recording screen.
- [ ] **Two iOS 26.5 failures that predate this pass.** `testSearchTabFocusAndKeyboardLeaveWithTab`: choosing the Transcripts tab from Search leaves the keyboard up on iOS 26.5 (MainView's `endEditing` doesn't reach it there). `testHeadingsScrollAway`: after scrolling the list and opening and closing Search, the tab bar stays minimized on iOS 26.5, so the Settings tab can't be tapped. Both fail identically with the baseline code (checked in a worktree of the first commit). Decide whether 26.5 gets a fix (e.g. expand the bar on a tab change) or the tests get a 27-only guard.
- [ ] **iOS 26.5 on screen.** iOS 26 gets the crossfade instead of the melt; check that it looks right (the suite passes functionally apart from the two items above).
- [ ] **Swipe to close and the audio actor on the iPhone.** The left-edge swipe, the back button, the haptics on the presses and the audio session/engine on the `AudioHardware` actor (start and Stop, AirPods route, interruptions) have been checked only in the simulator.
- [ ] **Check VoiceOver under the open card.** While the card is up, the list and the tab bar underneath are probably still reachable with VoiceOver. A likely fix is `.accessibilityHidden(true)` on the TabView while the card is presented.

## Record → transcript transition

- [ ] **The melt only runs at one screen width.** The bar positions were measured only on the 402 pt wide iPhone 17. Other Face ID widths assume the same 28 pt edge insets. Narrower iPhones, accessibility text sizes and iOS 26 get the crossfade. Measure the bar on other simulator widths, or derive its frames at runtime.
- [ ] **Long place names are unchecked on screen.** When the duration appears, a long place name should move from line 1 of the date line to line 2 (`DateLineLayout`). So far this has only been checked by reading the code. Check it with a long simulated place.
- [ ] **No turn if both states arrive at once.** If `.finishing` and `.finished` land in the same SwiftUI update, the turn doesn't happen and the transcript just appears. In practice `.finishing` has always been drawn first.
- [ ] **Merge the melt layer's two branches.** The melt layer sits over the Stop at 1 % opacity while recording, so its first frame doesn't stall. It lives in a separate if-branch from the turning one, so a new `MeltLayer` is still inserted at Stop. Merging the two branches would be safer.
- [ ] **Paragraphs overlap when speakers are refined.** When refined speakers arrive a few seconds after Stop, the old and new paragraphs overlap for about 0.3 s. A fix needs paragraph ids that stay stable across the re-split (`TranscriptAligner` / `TranscriptView`). Be careful with text selection and search hits.

## Tests

- [ ] **Tag chip tap in a list row.** No test covers it. It should open Search with the tag and must not open the card.
- [ ] **Card presentation race.** Opening a transcript while the card is still closing goes through `pendingCard` (`MainView.cardPhase == .closing`). No UI test covers it.
- [ ] **Midnight edge case.** `testRecordAccessoryFlow` checks for "Today at …". A recording that starts right at midnight would fail it.
- [x] **Decide on `-fakeSilence`.** Kept, with its test: it is the only way to reach the discarded path.

## Vocabulary: "Cofinpro" comes out as "Kufen Bro"

Findings (Mac, macOS 27, a synthesized German sentence): Apple's dictation model with the vocabulary as contextual strings writes "Cofinpro" (without it "Coin Pro"; the live model writes "KoFin Pro" with or without, it ignores contextual strings), so the biasing itself works. On the phone three things can still swallow it, all silently: the dictation pass runs under `try?` (a missing asset or an error leaves the words as they are); the merge window (the term's dictation time range ± 0.15 s must contain the middle of every replaced Parakeet word) can exclude the second word, so only "Kufen" is compared; and the edit-distance gate is at its limit for this pair ("kufenbro" vs "cofinpro" is 4 edits, the maximum at 8 letters; "Kufen Brot" fails). The pass also runs late (after the speakers, ~1 s per audio minute on an M5, slower on the phone).

- [ ] **Diagnose on the iPhone.** DEBUG-log which terms the dictation pass found, where, and why a merge was rejected (window or distance); store per transcript whether the pass ran. One recording saying "Cofinpro" then names the failing gate (`[Scribe] full-accuracy pass: … terms merged` in Console).
- [ ] **Phonetic matching as a second path** in `VocabularyMerge`: Kölner Phonetik codes "Cofinpro", "Kufen Bro", "Kufenbro" and "KoFin Pro" all as 43617 ("BaFin"/"Bufin" 136, "MaRisk"/"Marisk" 6784). Scan Parakeet's words in windows of 1–3 words and replace a span with the term's code, gated by a Parakeet confidence below 0.7 or a word the spell checker doesn't know ("Kaufen Pro" has the same code: the gate's test case). Works without the dictation pass and before it has run.
- [ ] **Loosen the merge:** window = the dictation word's range plus the gaps to its neighbours; distance limit relative to the shorter string.
- [ ] **People's names into the contextual strings** (acoustic biasing for free).
- [ ] **Measure** on the 80-clip harness: term accuracy and false replacements before and after. A Mac probe (`swiftc` + Speech, `say -v Anna`) reproduces the chain without a phone.

## Post-stop pipeline: visibility and order

- [ ] **Time each step on the iPhone** (signposts at the `[Scribe] queue:` boundaries; durations stored on the `Recording`, additive): words (Parakeet), speakers (Nemotron), vocabulary pass, title/summary. Nothing in this pipeline has been timed on a device.
- [ ] **Run the title before the vocabulary pass** (it needs only the final words), skip the vocabulary pass when the vocabulary is empty, keep Parakeet loaded briefly after a job.
- [ ] **Show the pipeline:** a step row under the date line ("Words · Speakers · Vocabulary · Summary", the active one with `.variableColor.iterative`, finished ones with a drawn checkmark and their time) replacing the three status strings; brief highlights on words changed by Parakeet and by the vocabulary pass; a shimmering placeholder and a streamed summary (`TitleAndSummary` is `@Generable`, Foundation Models can stream it; MLX streams too) with the `apple.intelligence` glyph; a pulsing `person.2.wave.2` in list rows while a transcript is in flight. Reduce Motion variants for all of it.
- [ ] **Smart Corrections with Gemma: an experiment, not a switch.** Whole-transcript context plus a glossary (People, vocabulary, place), edit list only, the existing code-side guards plus "never introduce a glossary term where nothing was suspect"; measure WER/CER, term and name accuracy and false edits on the 80 clips with Parakeet words. Ship only if not worse on WER and clearly better on terms; otherwise remove Smart Corrections (measured 11.0 → 11.2 % with Apple's model).

## Polish

- [x] **Faint chip edge in the grabber fade.** Gone with the grabber and its band: the content scrolls under the back button's glass.
- [ ] **Smart Corrections.** The experimental toggle (off by default, measured as not helping) and `TranscriptCorrector` are still in; removing them drops a visible setting, so it needs a decision.
- [ ] **TranscriptCorrector's `confidences` plumbing** goes with it (FileTranscriber.applyVocabulary, SpeakerIdentifier.BackgroundPass).
