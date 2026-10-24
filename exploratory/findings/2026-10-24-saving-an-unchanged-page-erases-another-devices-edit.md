# Saving an unchanged page erases another device's edit

- **Found**: 2026-10-24 · **Charter**: 02-sync-and-conflicts.md · **Status**: fixed (`NodeEditor`, three phases in `integration_test/sync_flow_test.dart`)

## What happens

Device A opens a page. Device B edits it. A's background sync pulls B's
version into A's database -- but A's open editor keeps showing the old text,
with no sign anything changed. A then presses Save **without typing a single
character**, and B's edit is gone: the server reverts to the old text and every
device converges on it.

## Reproduce

From a fresh `tool/explore.sh start`, with the browser configured as a
device (Settings → Advanced → server URL, `explore-token`, `explorer`):

```sh
# device B creates a page; A pulls it within 30s
tool/explore.mjs api POST /api/v1/sync '{"device_id":"device-b","cursor":0,"mutations":[...INSERT b-node-1...]}'
tool/explore.mjs click "From Device B"          # A opens it in the editor
# device B edits the body; A's background sync pulls it
tool/explore.mjs api POST /api/v1/sync '{"device_id":"device-b","cursor":1,"mutations":[...UPDATE body...]}'
tool/explore.mjs shot .explore/editor.png       # still the OLD body
tool/explore.mjs click "Save"                   # no edits made
tool/explore.mjs sql "SELECT body FROM nodes WHERE id='b-node-1'"
```

Observed:

```
body                        -- the server's live copy, after A's Save
written on the other device

seq  origin_device_id  body
1    device-b          written on the other device
2    device-b          B EDITED THIS -- important new text
3    <device A>        written on the other device
```

Expected: a Save with no changes writes nothing, and B's text stays.

## Why it matters

It is silent loss of someone's writing, triggered by the most innocent action
in the app. B's text survives only in the ChangeLog, which no user can see.

`docs/sync-protocol.md` does accept that Last-Write-Wins has no per-field
merge for *concurrent* edits. This is not that: A edited nothing. Two defects:

1. **Save writes unconditionally**, giving the unchanged text a fresh
   `updated_at` that beats any newer remote version.
2. **The open editor never learns a delta arrived**, so it shows stale text,
   and any real edit made from it overwrites the newer version too -- with no
   warning, although the app has everything it needs to give one.

## The fix

Both defects, in `NodeEditor`:

1. **A Save with no changes writes nothing.** The editor remembers the text
   and `updated_at` it was opened with; if the text is unchanged, Save says
   "No changes to save." and leaves the row alone.
2. **The editor watches its own row** through SQLite's update hook -- which
   deltas fire too, since `sync_mute` silences the outbox triggers but not the
   hook. With no unsaved edits it quietly shows the newer version. With unsaved
   edits it keeps them, shows a banner, and Save asks before replacing the
   newer version ("Show their version" / "Overwrite with mine"). Save re-reads
   the row at that moment rather than trusting the banner, because the hook is
   asynchronous.

Overwriting is still possible -- it is the user's text -- but only as an
informed choice. Last-Write-Wins itself is unchanged.

Verified in a browser through the same steps as above:

```
open editor after B's edit   -> shows "B EDITED THIS -- important new text"
Save, no edits               -> "No changes to save.", next sync pushed=0
server's copy                -> B's edit intact; ChangeLog has only B's entries
unsaved edit + B edits again -> banner, then on Save a "Changed on another
                                device" dialog instead of a silent overwrite
"Overwrite with mine"        -> A's text wins as seq 4; B's versions stay in
                                the ChangeLog
```
