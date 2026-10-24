# Pages that arrive by sync never appear in backlinks

- **Found**: 2026-10-24 · **Charter**: 04-wiki-links.md (suspected from reading the sync path) · **Status**: fixed (`client/lib/db/link_index.dart`, two phases in `integration_test/sync_flow_test.dart`)

## What happens

A page written on another device, linking to `[[Target]]`, syncs to this
device intact -- but Target's backlinks on this device say "Nothing links
here yet." Backlinks only ever show links that were saved on *this* device.

## Reproduce

From a fresh `tool/explore.sh start`, browser configured as device A
(Settings → Advanced → server URL, `explore-token`, `explorer`):

```sh
# device B creates "Linker" (body: "see [[Target]] for details") and "Target"
tool/explore.mjs api POST /api/v1/sync '{"device_id":"device-b","cursor":0,"mutations":[...]}'
# wait for A's background sync (deltas=2 in .explore/server.log)
tool/explore.mjs click "Target"
tool/explore.mjs text | grep -A1 -i backlinks
```

Observed: `Backlinks` / `Nothing links here yet.`, with Linker in A's page list.
Expected: Linker listed under Target's backlinks.

## Why it matters

Backlinks are half of what makes giki a wiki rather than a pile of notes, and
the multi-device case is exactly where they are needed: write on the phone,
read on the laptop, and the laptop's backlinks know nothing of what the phone
wrote. Nothing is lost -- the bodies are intact -- but the derived index is
silently incomplete, and it only repairs itself for a page if that page
happens to be re-saved locally.

## The cause

Two write paths into `nodes`. `NodeRepository.save` rebuilds the page's
entries in `links`; `GikiDatabase.applyDeltas` upserts the row and stops. The
server rebuilds links on every accepted mutation, so its index is fine.

Related and latent: `links.target_node_id` is resolved once, when the linking
page is written, and never revisited when the target page is created later --
on the server as well as the client. Nothing reads that column today
(backlinks match by `target_title_key`), so it is recorded here rather than
fixed.

## The fix

One function, `reindexLinks`, used by every path that writes a page: the
repository's save and delete, and `applyDeltas`. Removing the duplication is
the fix -- two write paths with one of them maintaining a derived index is how
this happened.

It rebuilds from the **stored** row, not from what the caller passed: after a
delta, the Last-Write-Wins guard may have kept the existing row, and indexing
the payload would index text that never landed. A test delivers an older
version that the guard rejects and checks the index did not move.

A fix that only acts going forward leaves the damage in place: every page
synced before it would stay missing from backlinks until re-saved. So
`ensureLinkIndex` rebuilds the whole index once per `linkIndexVersion`,
recorded in `sync_meta`, on the first start after the upgrade.

Verified in a browser through the reproduction above: Target's backlinks now
list Linker.
