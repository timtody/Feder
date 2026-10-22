Vocabulary bench (FED-56; README › After Stop: words, speakers, vocabulary). The app's post-stop vocabulary chain on
the Mac: SpeechTranscriber words (base, with confidences) -> DictationTranscriber with the vocabulary as contextual
strings (hinted) -> the app's own VocabularyMerge (merged). Vocabulary = Vocabulary.builtIn (the app's source).
  ./run.sh                 build, make missing or changed clips, score clips/synth.json and clips/mls.json -> out/report-*.txt
  ./run.sh --names         the four names of gen.py added to the contextual strings and the merge (FED-55's change)
  ./run.sh --short         a short list (gen.py SHORT: the 35 terms the sentences use) instead of the built-in 112,
                           like a user's own words (the shipping app sends only those: Vocabulary.current)
  ./run.sh --parakeet      Parakeet Ultra's words as the base (the app when Parakeet is chosen): builds
                           bench/parakeet.swift against the app's pinned FluidAudio checkout (FLUIDAUDIO=<dir>; default
                           the main checkout's build/DerivedDataSwipe, only read: built from a copy without .git in
                           .build/parakeet/FluidAudio) into .build/parakeet; needs the model downloaded
  ./run.sh --fresh         re-run the recognizers; otherwise their output is read from out/base*, out/hinted-*,
                           so a VocabularyMerge change (FED-53, FED-54) re-scores in seconds
The flags combine. gen.py synth: 104 sentences (68 with terms, 8 with names, 28 controls: 23 with a near miss of a
term, 5 plain) read by the de_DE voices Anna and Reed (Eloquence, a formant synthesizer, reported separately).
gen.py mls <dir>: DiarBench's 192 MLS clips with MLS's reference transcripts from <dir>/manifest.json (UTT=<dir>;
default ../diarbench/utt, in a worktree the main checkout's). The 80-clip set of the README's engine table (MINDS-14
calls, MLS excerpts) is not on disk.
Lure test (controls): the near miss's term put into the hinted words over it, as if the dictation pass had heard it
there; counts how often the merge writes it (its gate, what FED-54 loosens). A near miss that is the term apart from
case ("Dora" / "DORA") is listed as a case fix, not counted: VocabularyMerge.fixingCase rewrites it before any matching.
Report columns beyond term accuracy: "base no case" (the words pass with case ignored) and "case right" (right edits
that only change case) tell spelling fixes from misheard words the vocabulary brings in; word errors are counted for
every group, so an edit that swallows a correct neighbour shows up although terms are judged per clip.
Caches: each synthetic clip keeps the voice and sentence it was read from (clips/synth/<voice>/*.txt); gen.py reads a
changed one again and drops its cached passes if the audio differs. Each out/hinted-* folder keeps the vocabulary it
was made with (vocabulary.json) and is emptied when the list changes. A refused context is counted, and the pass runs
without it, as in the app.
Needs Apple's de_DE SpeechTranscriber and DictationTranscriber assets on the Mac; the bench never downloads them.
