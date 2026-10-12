---
name: catch-up
description: Explain in plain language what changed in Feder since the user last caught up, or since a date, commit or Linear issue given as argument, so they can follow the project without reading the code. Use when the user asks what changed, what happened since a day, what an issue's work did, or to catch up.
---

# Catch up on Feder

The user steers Feder but doesn't read the code line by line. Afterwards they should know what the app does differently, roughly how it works now, and what is waiting for them. Answer in the language of their message.

## 1. The range

- A date as argument ("monday", "2026-10-10"): the commits since then (`git log --since`).
- A commit: `<commit>..HEAD`.
- An issue (`FED-12`): the commits that name it (`git log --grep='FED-12'`), plus the issue and its comments.
- No argument: `refs/catch-up/last..HEAD` (`git rev-parse -q --verify refs/catch-up/last`); if that ref doesn't exist yet, the last 7 days.

Say the range in one line: from when, how many commits.

## 2. Read

- `git log --reverse --date=short --format='%h %ad %s%n%b' <range>` and `git diff --stat <range>`.
- What users got: the lines added to `CHANGELOG.md` in the range.
- Linear (team `FED`): the issues updated since the start, with their comments (the sessions' notes); new `Decision` and `Device-only` issues.
- Work in progress: `git status --short` and `git worktree list`. Uncommitted changes (often another session's) are "in progress", not done.
- For each group below, open the two or three places in the code that carry it, enough to explain it correctly. Don't describe code you haven't read.

## 3. Write

Group by what the user would recognise (a feature, a fix, a cleanup nobody sees), not by commit. Per group:

- **What changed:** for someone using the app, one or two sentences ("nothing visible" is a fine answer).
- **How it works now:** two to four plain sentences, at most three `path:line` pointers; explain a term the first time it appears.
- **Verified / open:** what was tested or looked at, what still needs the iPhone, with FED links.

Then three short lists, each left out when empty: **Try on your iPhone**, **Waiting for your decision** (`Decision` issues), **Worth a look** (stored data changed, a new download or permission, anything near "nothing leaves the phone", a test skipped or failing).

About one screen per 20 commits. A small diagram helps when a flow changed.

## 4. Remember

Without an argument, after the summary: `git update-ref refs/catch-up/last HEAD`, and say so in one line ("Next /catch-up starts after abc1234"). With an argument, leave the marker alone.
