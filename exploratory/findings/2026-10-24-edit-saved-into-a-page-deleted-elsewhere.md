# An edit saved into a page deleted elsewhere vanishes

- **Found**: 2026-10-24 · **Charter**: 02-sync-and-conflicts.md · **Status**: fixed (`NodeEditor`, `NodeRepository.save`, two phases in `integration_test/sync_flow_test.dart`)

## What happens

Device A has a page open. Device B deletes it; A's background sync pulls the
tombstone. A's editor shows nothing. A types and presses Save: "Saved locally.
It will sync in the background." But `save()` upserted title and body without
touching `is_deleted`, so the text went into the tombstone. The page left A's
list, the push replicated the tombstone with the new body, and the text was
invisible on every device.

## Reproduce

From a fresh `tool/explore.sh start`, browser configured as a device:

```sh
tool/explore.mjs click "New page"; fill Title/Body; click "Save"   # A, editor stays open
tool/explore.mjs api POST /api/v1/sync '{"device_id":"device-b","cursor":1,"mutations":[...UPDATE is_deleted=1...]}'
# wait for A's next sync, then in A's still-open editor:
tool/explore.mjs fill "Body" "typed after the delete arrived"; tool/explore.mjs click "Save"
tool/explore.mjs sql "SELECT body, is_deleted FROM nodes"
```

Observed:

```
body                            is_deleted
typed after the delete arrived  1
```

## Related, not a bug

If A saves *before* the tombstone arrives, A's edit carries the newer
timestamp and Last-Write-Wins resurrects the page; neither device is told.
That keeps the data, so it stays as designed.

## Fix

The editor notices its page disappeared and shows a banner, keeping the text.
Save then asks "Restore with my text" / "Discard my text"; `save()` clears
`is_deleted`, so a restore replicates. Verified in the browser: banner, dialog,
then the server holds the typed body with `is_deleted = 0`.
