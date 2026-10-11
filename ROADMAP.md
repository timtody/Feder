# Feder roadmap

Ideas after 1.0 (October 2026), most valuable first within each tier. Everything stays on the phone; where a feature
touches the network or iCloud it says so, since that is a product decision.

## P1: soon after release (1.1–1.2), high value, small to medium effort

1. **Better live speaker labels.** Replace LS-EEND with streaming Sortformer (already in FluidAudio): 92–94 % of words
   right against 82–85 % on the Mac bench, new speakers labelled within about 2.3 s instead of up to 19 s. Start behind
   a Debug switch and compare both on a real problem recording from the iPhone. Limits: 4 speakers, about 235 MB, load
   next to SpeechAnalyzer unmeasured. "Everything under Speaker 1" is the biggest quality gap users will notice.
2. **Live Activity and Dynamic Island while recording.** Timer, level and Stop on the Lock Screen, like Voice Memos.
   People lock the phone during meetings.
3. **Start from anywhere.** Control Center control, Action Button, Siri/Shortcuts ("Start transcribing") and a Lock
   Screen widget (App Intents). Recording is time-critical: the conversation is starting now.
4. **Import audio.** From Voice Memos, Files or the share sheet, transcribed offline with the same steps as after Stop.
   Makes Feder the place for all audio, not only new recordings.
5. **Tap a word to hear it** (if the audio is kept). Playback highlights the words as they are spoken; a tap on a word
   jumps there. The most requested feature in apps of this kind, and it lets users check doubtful words.
6. **Fix a word in place.** Long-press a word to edit it, with an option to add the correction to the vocabulary so it
   is right next time.
7. **Correct speakers.** Move a paragraph to another speaker, merge two speakers, split one. Today a wrong label can
   only be fixed by recounting the speakers.
8. **Exports.** PDF, Markdown, DOCX and subtitles (SRT/VTT), with or without speaker names and timestamps.
9. **Spotlight search.** Index the transcripts locally (CoreSpotlight), so a search on the home screen finds "budget
   meeting".

## P2: features that set Feder apart (1.x)

10. **Bookmarks while recording.** A "mark" button, or a squeeze of the Action Button, flags a moment ("that was
    important"); the marks show in the transcript and the summary.
11. **Action items to Reminders and Calendar.** Gemma pulls out to-dos ("Anna sends the numbers by Friday"); one tap
    adds them to Reminders or Calendar (EventKit, local).
12. **Summary styles.** Meeting (decisions, to-dos, open questions), lecture (key ideas), interview (questions and
    answers), or just bullet points; a style can be set per tag.
13. **Chapters.** Gemma splits long recordings into topics with timestamps; the chapter list jumps around.
14. **Calendar context.** If a calendar event is running when Transcribe is pressed, its title becomes the transcript's
    and its attendees are offered as speaker names. Takes the most effort out of naming.
15. **Person pages.** What a person said across all transcripts, when you last spoke, recurring topics. Builds on People
    and voice recognition.
16. **App lock.** Face ID to open Feder. Fits a privacy-first app and costs little.

## P3: bigger bets

17. **Ask your transcripts.** On-device questions over one transcript or the whole archive ("What did we decide about
    the licences?"), answered with links to the exact passages (Gemma and a local search index). Could be Feder's
    signature feature.
18. **Live translation.** Translated subtitles as people speak, with Apple's on-device Translation framework. For
    international meetings; nothing goes online.
19. **Captions mode for accessibility.** Large, high-contrast live text with speaker colours, the phone turned so the
    other person can read along. Really helps people who are hard of hearing; also a strong point when pitching for an
    App Store feature.
20. **Conversation insights.** Talk-time share per person, speaking pace, interruptions, filler words. Optional, as
    coaching rather than surveillance.
21. **Prepare for a meeting.** Before a calendar event, a short summary of earlier meetings with the same people:
    "Last time: …, open: …".
22. **Redaction for sharing.** Exports with names, phone numbers, IBANs or chosen words blacked out automatically.

## Moonshots

23. **Apple Watch as remote and microphone.** Start, stop and mark from the wrist.
24. **Mac app with local hand-off.** Transcripts between Mac and iPhone by AirDrop or the local network, no cloud.
25. **Voice commands while recording.** "Feder, mark that", "Feder, new topic".
26. **Lecture mode with photos.** Photos of slides or the whiteboard taken during the recording go into the transcript
    at their moment.

## Decisions to make first

- **Backup and sync.** A lost phone can mean lost transcripts. An encrypted export to Files, started by the user, keeps
  the promise; iCloud sync would bend "nothing leaves the phone" and needs a clear decision and wording in the privacy
  policy before anything is built.
- **Keeping the audio.** P1 #5, checking doubtful words and redaction depend on it. That means storage, and a storage
  manager (for example: delete the audio after 30 days, keep the text).

## Suggested for 1.1

#1, #2, #3 and #5: they close the biggest quality gap and make every use of the app feel finished.
