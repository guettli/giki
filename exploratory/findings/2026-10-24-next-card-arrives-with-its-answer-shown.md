# The next card arrives with its answer already shown

- **Found**: 2026-10-24 · **Charter**: 05-spaced-repetition.md · **Status**: fixed (`StudyPage`, a phase in `integration_test/sync_flow_test.dart`)

## What happens

Device A shows a card with its answer revealed. Device B deletes (or answers)
that card. A's next background sync rebuilds the study page, the card is gone,
and the next one appears with its answer already visible and the rating
buttons live. "Answer shown" was one flag for the page, not for a card.

## Reproduce

From a fresh `tool/explore.sh start`, device A pointed at the server:

```sh
tool/explore.mjs click Study
# two cards: "Capital of France?" / Paris, "Capital of Peru?" / Lima; sync
tool/explore.mjs click "Show answer"                  # France, Paris shown
tool/explore.mjs api POST /api/v1/sync '{... "table":"cards", <France>, "is_deleted":1 ...}'
# wait for A's background sync (30 s)
tool/explore.mjs text
```

Observed: `Capital of Peru?`, `Lima`, and the buttons again/hard/good/easy.
Expected: `Capital of Peru?` and "Show answer".

## Why it matters

The rating is the user's own judgement of recall. A card whose answer was on
screen before the question was read gets a rating that measures nothing, and
the schedule is built on it. It happens on every sync while the study tab is
open and another device studies too.
