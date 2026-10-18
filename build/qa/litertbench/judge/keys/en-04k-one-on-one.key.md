# Key: en-04k-one-on-one
Language: en · Characters: 4022 · Speakers: 2
## Must cover
- Incident feedback (checkout outage, October 7): communication was good, but the rollback was too slow because the team debated fixing forward; Marcus agrees fixing forward was the wrong call.
- New rule: for a config change, once an incident is past 10 minutes, roll back without debate.
- Promotion: Marcus goes up for staff engineer in the February cycle; the packet must show two examples of cross-team influence (candidates: API versioning with the payments team, the on-call guide); Raj is to be his sponsor.
- Conference talk: Marcus submits to Northbridge DevCon (Rotterdam) on the feature flag system (about 300 flags moved off the old service with zero downtime), not on the incident.
- Workload: Marcus is on three projects (feature flag migration, search rewrite, billing migration); billing goes to Priya, so he is down to two projects.
- On-call in December: Marcus stays on, but for one week instead of two (Dana to double-check the schedule).
## Facts (numbers, dates, names)
- Incident: checkout outage on October 7, 47 minutes total, about 20 minutes of it spent arguing whether to roll back
- About 12,000 checkouts lost during the outage
- Status channel was up within about 5 minutes
- Rollback threshold for config changes: 10 minutes
- Postmortem due Friday, October 24
- Promotion committee (calibration) meets February 3; packet due January 9
- Northbridge DevCon, Rotterdam; CFP closes November 14
- About 300 feature flags migrated with zero downtime
- People: Dana (manager), Marcus (senior engineer), Raj (sponsor), Priya (takes over billing)
- Handover with Priya: a one-hour session next week
## Tasks
- Marcus: write the postmortem, including the rollback rule (Friday, October 24)
- Marcus: send Dana a draft talk abstract (November 7)
- Dana: ask Raj to be Marcus's promotion sponsor (end of the month)
- Dana: talk to Priya about taking over the billing migration (Wednesday)
- Marcus: hold a one-hour billing handover with Priya (next week, after Dana has talked to her)
- Marcus: submit the promotion packet (January 9)
- Dana: double-check the December on-call schedule (no deadline)
## Traps
- Dana proposes the October 7 incident as Marcus's conference talk topic → rejected (legal is still reviewing the customer impact); the talk is about the feature flag system
- Dana proposes Marcus keep the billing migration with the deadline pushed out a month → rejected; billing goes to Priya
## Misheard words
- celebration = calibration ("The promo celebration is February 3rd")
- feature flak = feature flag ("the feature flak migration")
