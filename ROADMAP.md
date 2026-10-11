# Feder roadmap

Ideas after 1.1 (rewritten October 11, 2026), most valuable first within each tier. Everything stays on the phone;
where a feature touches the network, iCloud or another app it says so, since that is a product decision. What users
already got is in CHANGELOG.md.

## Done since the first roadmap (1.1, in progress)

Live Activity and Dynamic Island while recording; start from Control Center, the Action Button, Siri, Shortcuts and a
lock screen widget; Edit Text with Your Words; speaker corrections (assign a part, new speaker, merge); Share as PDF,
Word, Markdown and subtitles; iPhone Search (opt-in); titles and summaries in the iPhone's language.

## P1: next (1.2), high value, small to medium effort

1. **Better live speaker labels.** Still the biggest quality gap: LS-EEND puts much of a conversation under Speaker 1.
   Streaming Sortformer (already in FluidAudio) scored 92–94 % of words right against 82–85 % on the Mac bench and
   labelled new speakers within about 2.3 s instead of up to 19 s. Start behind a Debug switch and compare both on a
   real problem recording from the iPhone (a WAV where it went wrong). Limits: 4 speakers, about 235 MB, load next to
   SpeechAnalyzer unmeasured.
2. **Tap a word to hear it.** The audio is kept already. Playback highlights the words as they are spoken, a tap on a
   word jumps there, and a doubtful word can be checked before it is corrected with Edit Text. Pairs naturally with
   the existing corrections.
3. **Import audio.** From Voice Memos, Files or the share sheet, transcribed offline with the same steps as after Stop
   (words, speakers, vocabulary, summary). Makes Feder the place for all audio, not only new recordings.
4. **Undo for corrections.** Assign, merge and text edits are final today (merge asks first). One level of Undo in the
   card (shake or a toast's Undo) makes them safe to try.
5. **A paragraph to another speaker.** Today a whole turn moves (the name row's menu). In Edit Text, a speaker chip
   above each paragraph would move a single paragraph, for turns the diarizer ran together.
6. **The rename tip in one tap.** A popover tip takes the first tap to close, so naming takes two taps the first time.
   An inline tip under the first name row, or a tip with a Rename action, avoids it.

## P2: features that set Feder apart (1.x)

7. **Bookmarks while recording.** A mark button in the card and the Live Activity (or a squeeze of the Action Button)
   flags a moment; the marks show in the transcript, in exports and in the summary.
8. **Action items to Reminders and Calendar.** Gemma pulls out to-dos ("Anna sends the numbers by Friday"); one tap
   adds them to Reminders or Calendar (EventKit, on the iPhone; needs permission).
9. **Summary styles.** Meeting (decisions, to-dos, open questions), lecture (key ideas), interview (questions and
   answers), or bullet points; a style per tag.
10. **Chapters.** Gemma splits long recordings into topics with timestamps; a chapter list jumps around, and the
    exports get headings.
11. **Calendar context.** A calendar event running when Transcribe is pressed names the transcript and offers its
    attendees as speaker names (needs calendar permission; names only, nothing leaves the iPhone).
12. **Person pages.** What a person said across all transcripts, when you last spoke, recurring topics. Builds on
    People and voice recognition.
13. **App lock.** Face ID to open Feder, and optionally to hide transcripts from the share sheet and iPhone Search
    while locked. Fits a privacy-first app and costs little.

## P3: bigger bets

14. **Ask your transcripts.** On-device questions over one transcript or the whole archive ("What did we decide about
    the licences?"), answered with links to the exact passages (Gemma and a local search index). Could be Feder's
    signature feature.
15. **Live translation.** Translated subtitles as people speak, with Apple's on-device Translation framework.
16. **Captions mode for accessibility.** Large, high-contrast live text with speaker colours, the phone turned so the
    other person can read along. Helps people who are hard of hearing, and is a strong point for an App Store feature.
17. **Conversation insights.** Talk-time share per person, speaking pace, interruptions, filler words. Optional,
    framed as coaching rather than surveillance.
18. **Prepare for a meeting.** Before a calendar event, a short summary of earlier meetings with the same people.
19. **Redaction for sharing.** Exports with names, phone numbers, IBANs or chosen words blacked out automatically.

## Moonshots

20. **Apple Watch as remote and microphone.** Start, stop and mark from the wrist.
21. **Mac app with local hand-off.** Transcripts between Mac and iPhone by AirDrop or the local network, no cloud.
22. **Voice commands while recording.** "Feder, mark that", "Feder, new topic".
23. **Lecture mode with photos.** Photos of slides or the whiteboard taken during the recording go into the transcript
    at their moment.

## Decisions to make first

- **Backup and sync.** A lost phone can mean lost transcripts beyond the iPhone's own backup. An encrypted export to
  Files, started by the user, keeps the promise; iCloud sync would bend "nothing leaves the phone" and needs a clear
  decision and wording in the privacy policy first.
- **How long audio is kept.** Tap-to-hear (P1 #2) makes the audio more valuable, and it takes space. A storage manager
  (for example: delete the audio after 30 days, keep the text) needs a default.
- **What the 1.1 release contains.** Everything above "Done" is on main now; decide whether it ships as 1.0's first
  TestFlight build or as 1.1 after it (CHANGELOG.md lists it under 1.1).

## Known gaps to check on the iPhone

The real Spotlight results, the Control Center control with the feather, the Live Activity on the actual lock screen,
German summaries from Gemma, and the iPhone-only items in TASKS.md (live labels on a real conversation, the search
keyboard test on the software keyboard).

## Suggested for 1.2

#1, #2, #4 and #6: the biggest quality gap, the feature that makes corrections trustworthy, and two small fixes to
things users meet in their first minutes.
