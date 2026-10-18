# Key: de-07k-sprint-review
Language: de · Characters: 7058 · Speakers: 4
## Must cover
- Sprint 14 finished: real-time departures at the stop, day ticket in the purchase flow, push notifications for delays (delay endpoint now polls every 30 s instead of every 2 min)
- Velocity: 29 of 34 committed story points done; the "Favoriten-Haltestellen" story (5 points) was not finished (pull request unreviewed) and moves into Sprint 15
- Bug in release 1.4.2: Schülermonatskarte in tariff zone 3 charged 49 € instead of 39 € (student discount not applied; zone 3 had no unit tests); hotfix 1.4.3 is out
- Decision: the 32 affected buyers get 10 € back automatically (320 € total, borne by Regionalbus Hellmark) and are written to
- Demo: buying a day ticket now takes 3 taps to payment instead of 7; delay shown in red; push notifications can only be turned off globally, per-line muting becomes a new backlog story
- Decision: offline tickets are built in Sprint 15 behind a feature flag and go live on 12 November, not 31 October, because the buses' ticket checking devices only get the firmware for the new QR code on 10 November
- Decision: Sprint 15 is planned at 26 points (Jonas on leave, average velocity 29): Favoriten-Haltestellen 5, VoiceOver labels in the purchase flow 3, rest offline tickets; per-line push muting waits
- Crash-free rate up to 99.2 % (from 98.7 %); store rating 4.1, down from 4.3 after the bug
## Facts (numbers, dates, names)
- Product: app "Hellmark mobil" for the fictional bus company Regionalbus Hellmark; contact there: Herr Dahlke
- Speakers: Miriam (moderates, likely Scrum Master), Katrin (product side, talks to the client), Jonas (app developer, gives the demo), Sprecher 3 (backend developer, unnamed)
- Sprint 14 reviewed; Sprint 15 runs 20 October to 31 October
- 34 points committed, 29 done; velocity of the last three sprints 27, 31, 29 (average 29); Sprint 15 planned at 26
- Release 1.4.2 shipped Tuesday 14 October with the price bug; hotfix 1.4.3 since Thursday morning 16 October
- 49 € charged instead of 39 €, 10 € too much per card, 32 purchases, 320 € refunded
- Unit tests existed only for tariff zones 1 and 2; there are 5 tariff zones
- Delay endpoint polls every 30 seconds (previously 2 minutes)
- Demo: stop Marktplatz, line 412 with 4 then 5 minutes delay; 3 taps instead of 7
- Crash-free rate 99.2 % (previous sprint 98.7 %), improved by a fix to timetable caching on cold start; store rating 4.1 (before 4.3)
- Firmware for the checking devices on 10 November; offline tickets live 12 November (2 days buffer)
- Jonas on leave 30 and 31 October
- Accessibility audit in December (reason for VoiceOver labels)
- Retro at 2 o'clock; Katrin's call with Herr Dahlke after the review (she leaves at 11:30)
## Tasks
- Miriam: agree the refund email to the 32 affected customers with support (Tuesday 21 October)
- Sprecher 3: write regression tests for all five tariff zones with all discounts (Wednesday 22 October)
- Katrin: get confirmation that the firmware date of 10 November is fixed (Monday 20 October); tell Herr Dahlke about the new date in today's call (today)
- Jonas: build the feature flag for offline tickets (29 October)
- Katrin: add per-line push muting as a story to the backlog (no deadline)
## Traps
- Katrin early: offline tickets go live at sprint end on 31 October (already promised to Herr Dahlke) → they go live on 12 November behind a feature flag, because the checking devices can only read the new QR code after the firmware update on 10 November
## Misheard words
- Steaking-Umgebung = Staging-Umgebung
- Tarifsonne = Tarifzone
- Kontrollgerede = Kontrollgeräte
