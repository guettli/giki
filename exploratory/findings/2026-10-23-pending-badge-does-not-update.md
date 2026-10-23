# The "changes waiting" badge does not update after an edit

- **Found**: 2026-10-23 · **Charter**: 01-offline-first.md · **Status**: fixed (`GikiDatabase.pendingChanges`, asserted in `integration_test/sync_flow_test.dart`)

## What happens

Save a page, return to the list, and the sync button still says "Sync now"
with no badge -- although the edit is sitting in the outbox waiting to be
pushed. The badge appears only when something else happens to rebuild the app
shell.

## Reproduce

From a fresh `tool/explore.sh start`:

```sh
tool/explore.mjs open /
tool/explore.mjs click "New page"
tool/explore.mjs fill "#0" "Leitner"
tool/explore.mjs click "Save"
tool/explore.mjs click "Back"
tool/explore.mjs text | grep -i sync
```

Observed: `[button] Sync now`
Expected: `[button] 1 change(s) waiting`, as the tooltip is written to show.

## Why it matters

The badge is the only indication that work has not reached the server. A user
who closes the tab trusting "Sync now" has in fact left an unsynced edit
behind. Nothing is lost -- the outbox survives -- but the one signal the app
gives about sync state is wrong exactly when it matters.

## The cause, and the fix

`HomePage.build` read `db.pendingCount` once per build, and editing happens in
a child route that calls `setState` on `WikiPage`, which does not rebuild the
shell above it.

The count is now a `ValueNotifier` fed by **SQLite's own update hook** on
`sync_outbox`, and the badge is a `ValueListenableBuilder`. The hook rather
than a `notify()` at each write site, because the outbox is written by
*triggers*: the writes that matter are the ones no Dart code performs, and a
hand-maintained count would be correct only until the next repository method
forgot to announce itself -- which is how this bug happened in the first place.

Verified in a browser from the reproduction above: the badge now reads
`1 change(s) waiting` immediately after returning from the editor.
