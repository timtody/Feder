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
6. **The rename tip in one tap:** the first tap on a name renames, with the tip still showing. Open: that tap feels
   very slow on the iPhone; measure it (`-interactionTrace`, Time Profiler) and make it answer in its frame.

From P2 (October 12, 2026):

- **#8 Action items to Reminders and Calendar:** Gemma lists who does what by when, only when asked: the card's Action
  Items button opens a sheet (October 12, 2026: no longer after every recording, since Gemma found tasks where there
  were none; the button replaced the speaker-count menu, which is gone; no button at all on iPhones that can't run
  Gemma); one tap adds an item to Reminders (asks for access the first time) or opens Apple's New Event screen,
  prefilled (no access needed); "Add All to Reminders"; Share as text; a reminder links back to its transcript;
  Markdown, PDF and Word exports list them.
- **#11 Name from Calendar:** opt-in in Settings › Recording (no onboarding page: a page before a system prompt is an
  App Review risk); a transcript started during a calendar event gets its name, and the rename sheet offers its
  invitees (names only, no addresses). A Preferred Calendar (below the switch, None by default, laid out like iOS's
  Default Calendar page) wins when two events overlap.
- **#12 Person pages:** the contact-card page in Settings › People and "Go to Person" from a name row: last
  conversation, recurring topics (from Gemma's topics, tags and summaries), one quote per transcript that opens the card
  where they speak; search also finds the topics.
- **#13 App Lock:** optional, off by default ("Require Face ID", locks at once or after 1, 5 or 15 minutes, and when the
  iPhone locks); recording from outside still starts, the Live Activity shows no words; iOS's own "Require Face ID"
  (touch and hold the icon) is the alternative.

## P2: features that set Feder apart (1.x)

7. **Bookmarks while recording.** A mark button in the card and the Live Activity (or a squeeze of the Action Button)
   flags a moment; the marks show in the transcript, in exports and in the summary. In the Live Activity the mark
   button sits on the left, next to the time, away from Stop.
9. **Summary styles.** Meeting (decisions, to-dos, open questions), lecture (key ideas), interview (questions and
   answers), or bullet points; a style per tag. Only with Gemma, so only on 8 GB iPhones: the UI must work without
   it. The type can be set while recording and changed afterwards, which writes the summary again; the unfolded
   summary offers another style on demand.
10. **Chapters.** Gemma splits long recordings into topics with timestamps; a chapter list jumps around, and the
    exports get headings. Configurable (on or off). The open question is where chapters show without disturbing the
    card. One idea: a "…" button in the bottom toolbar for more options, which could also hold "Rewrite Summary",
    perhaps under "AI Features". The toolbar is full now (Share, Add Tag, Edit Text, Action Items, Listen, Delete), so
    a "…" would take some of these in.

## P3: bigger bets

14. **Ask your transcripts.** On-device questions over one transcript or the whole archive ("What did we decide about
    the licences?"), answered with links to the exact passages (Gemma and a local search index). Could be Feder's
    signature feature. Only with Gemma on 8 GB iPhones: other models make little sense here.
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
Voice Memos' share sheet, and Sortformer on the iPhone (see Done in 1.2, item 1); App Lock's real Face ID and passcode
fallback, one scan when recording starts from a locked iPhone, and the iPhone locking during a grace period; Name from
Calendar with real iCloud, Exchange and Google calendars (read-only calendars, invitations); Reminders and the New Event
screen with real lists and calendars; the person pages' topics on a real German archive; shake to undo Remove in
the Action Items sheet (the simulator can't shake, and ⌘Z doesn't reach the sheet there); the Action Items button with
the real Gemma (time per request, items in real meetings); the Preferred Calendar with real accounts, also after a
calendar's identifier changed.

## Suggested next

The rename tip's slow first tap (Done in 1.2, item 6), then Sortformer as the default once the iPhone check holds (Done in 1.2, item 1), then #7 (bookmarks while recording) and #9
(summary styles, which can build on the action items). A small follow-up to Import: "Transcribe Again in…" for a
transcript, since an import's language is detected (three windows vote) and a recording that mixes languages can still
come out in the wrong one; today its words are written once.
