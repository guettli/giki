# A card first reviewed on two devices never leaves the study queue

- **Found**: 2026-10-24 · **Charter**: 05-spaced-repetition.md (suspected from reading `CardRepository.review`) · **Status**: fixed (`srsStateId`, `mergeDuplicateSchedules`, three browser phases, unit tests on VM and Chrome)

## What happens

The same user reviews a new card on two devices before they sync. Each
device creates its own schedule row for that card, with its own random id.
After syncing there are two schedules for one card and one user, and the
study queue keeps offering the card no matter how often it is answered.

## Reproduce

From a fresh `tool/explore.sh start`, browser configured as device A:

```sh
tool/explore.mjs click "Study"; tool/explore.mjs click "New card"
tool/explore.mjs fill "Front" "Leitner box 3 interval?"; tool/explore.mjs fill "Back" "3 days"
tool/explore.mjs click "Create"
tool/explore.mjs click "Show answer"; tool/explore.mjs click "good"   # A's schedule
# device B, same user, offline until now: its own first review, rated "again"
tool/explore.mjs api POST /api/v1/sync '{"device_id":"device-b",...,"table":"srs_state","record_id":"b-srs-for-same-card",...,"due_at":"<a minute ago>"}'
# after A pulls it, answer the card "good" three times
```

Observed:

```
schedules for one card, one user:   2
A's study tab after three "good":   1 due · box 1 of 6   (still)
```

Expected: one schedule per card and user, and a card answered "good" moving
up a box and out of today's queue.

## Why it matters

Studying the same deck on a phone and a laptop is the obvious way to use a
local-first flashcard app, and it is exactly the case that breaks. Every
review is recorded -- the history is not lost -- but the card is stuck, and
nothing in the app explains why.

## The cause

`srs_state` promises "one row per (card, user)" in its schema comment, and
nothing enforces it. `review()` looks the row up by (card, user) and, finding
none, mints a random id; two devices that each find none mint two ids.
Last-Write-Wins merges versions of a row, never two different rows. And
`review()` then updates whichever of the two its query returns first, while
the study queue joins the other.

## The fix

The invariant is now enforced by construction rather than by luck.

1. **Name-based ids.** A schedule's id is derived from (card, user):
   `srsStateId` is a version 8 UUID from SHA-256. Two offline devices that both
   review a new card compute the *same* id, so their versions are versions of
   one row, and Last-Write-Wins merges them as designed. A unique constraint
   would have done the opposite: rejected one device's write after it had
   already been made offline.
2. **A queue that cannot double up.** `due()` joins only the newest schedule
   per card, so a duplicate from a device still on an older version cannot
   offer the card twice or keep it after it was answered.
3. **Existing duplicates are merged** on every start by
   `mergeDuplicateSchedules`: the newest wins under the name-based id, the
   others are tombstoned, and both go through the outbox so every device
   converges. Every start rather than once, because an older client can still
   produce a duplicate; finding none is one query.

Verified in a browser through the reproduction above:

```
old client's "again" arrives   -> 1 due · box 1 of 6   (correct: newest says due)
one "good"                     -> Nothing due.          (was: stuck after three)
reload, then sync              -> server: name-based row live, old row tombstoned
```
