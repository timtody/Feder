# Feder roadmap

Ideas after 1.1 (rewritten October 11, 2026), most valuable first within each tier. Everything stays on the phone;
where a feature touches the network, iCloud or another app it says so, since that is a product decision. What users
already got is in CHANGELOG.md.

## Done since the first roadmap (1.1, in progress)

Live Activity and Dynamic Island while recording; start from Control Center, the Action Button, Siri, Shortcuts and a
lock screen widget; Edit Text with Your Words; speaker corrections (assign a part, new speaker, merge); Share as PDF,
Word, Markdown and subtitles; iPhone Search (opt-in); titles and summaries in the iPhone's language.

## Done in 1.2 (in progress): the former P1

1. **Better live speaker labels: Sortformer behind a Debug switch** (Settings › About › Live Labels Model in Debug
   builds; release builds keep LS-EEND). Mac bench, 12 meetings, words right when first labelled: 93.0 % against
   86.3 % with noise (−55 dBFS, four seeds), 93.9 % against 81.9 % clean; a new speaker labelled after 1.5 s (p50) and
   no speaker missed. Still to do before it becomes the default: compare both on a real problem recording on the
   iPhone, check memory next to Nemotron and Gemma (236 MB model), the first Neural Engine compile and the live text's
   delay, and add Sortformer (CC-BY-4.0) to the acknowledgements. Limits: 4 speakers, 246 MB download.
2. **Listen** (tap a word to hear it): the headphones in a transcript's toolbar show a player; the spoken word lights
   up and stays on screen, a tap on a word plays from it, and the lock screen and AirPods control it. A mode, not
   always on: off, a transcript is plain text as before.
3. **Import audio** from the record accessory's Import button (right of the language; minimized, it stays on the right
   and the language goes) and from the share sheet of Voice Memos, Files and other apps; the same steps as after Stop.
4. **Undo for corrections:** a toast's Undo or a shake takes back the last speaker change, merge or text edit.
5. **A paragraph to another speaker:** Edit Text has a speaker chip above each paragraph.
6. **The rename tip in one tap:** the first tap on a name renames, with the tip still showing.

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
- **How long audio is kept.** Listen and Import make the audio more valuable, and it takes space. A storage manager
  (for example: delete the audio after 30 days, keep the text) needs a default.
- **What the 1.1 release contains.** Everything above "Done" is on main now; decide whether it ships as 1.0's first
  TestFlight build or as 1.1 after it (CHANGELOG.md lists it under 1.1).

## Known gaps to check on the iPhone

The real Spotlight results, the Control Center control with the feather, the Live Activity on the actual lock screen,
German summaries from Gemma, and the iPhone-only items in TASKS.md (live labels on a real conversation, the search
keyboard test on the software keyboard). From 1.2: Listen's Now Playing on the lock screen and the AirPods, Import from
Voice Memos' share sheet, and Sortformer on the iPhone (see Done in 1.2, item 1).

## Suggested next

Sortformer as the default once the iPhone check holds (item 1 above), then #7 (bookmarks while recording) and #13 (app
lock): both small, and both fit the recording and privacy promise.
