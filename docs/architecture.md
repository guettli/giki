# Architecture

## The shape of it

giki is two programs that share a SQL schema:

* **The client** is a Flutter Web PWA with SQLite compiled to WebAssembly. The
  local database is the source of truth. The UI reads it synchronously and
  writes to it synchronously; nothing in the user's path waits for a network
  request.
* **The server** is a single static Go binary with its own SQLite file. It is a
  convergence point and an audit log, not a source of truth.

`db/schema.sql` is applied verbatim on both sides. `tool/sync-schema.sh` copies
it into the client's assets and CI fails if the copies drift, which is what
keeps "isomorphic schema" from being an aspiration.

## Why the outbox is in SQL

The alternative is an application-level write path: every mutation goes through
a function that also records it for sync. That works until someone writes an
`UPDATE` somewhere else, and then the change exists locally but never reaches
the server -- a bug that looks like data loss and takes days to find.

Triggers close that hole. Any statement that touches a syncable table produces
an outbox row, including ones written by code that has never heard of sync. The
payload is built by `json_object()` in SQL, so the wire format comes from the
database rather than from a marshalling layer that can drift from it.

The cost is explicitness: every table needs three triggers, each listing its
columns. `TestTriggerPayloadsMatchRegistry` runs the real triggers and compares
their payload keys against the server's allowlist, so a forgotten column fails
a test instead of silently never syncing.

## Breaking the echo loop

Writing server deltas into the local database fires the same triggers, which
would push those rows straight back to the server. Two defences:

1. **`sync_mute`.** While deltas are applied, a row sits in that table and every
   trigger body carries `WHERE NOT EXISTS (SELECT 1 FROM sync_mute)`, so the
   insert simply writes nothing. Triggers are never dropped or recreated at
   runtime -- a crash mid-sync would otherwise leave a database with no outbox
   triggers at all, which is unrecoverable data loss.
   (The guard lives in the trigger body because SQLite does not allow a
   subquery in a trigger's `WHEN` clause.)
2. **`origin_device_id`.** The server never sends a change back to the device
   that pushed it.

## Tables

| Table | Synced | Notes |
| --- | --- | --- |
| `users`, `nodes`, `cards`, `srs_state`, `review_log` | yes | UUIDv7 ids, `updated_at`, `is_deleted`. No foreign keys: a delta batch may legitimately deliver a card before its node. |
| `links` | no | Derived from `nodes.body` by both sides. Rebuilt on every write, so it carries no sync columns. |
| `sync_outbox`, `sync_mute`, `sync_meta` | no | Client only. |
| `change_log`, `devices` | no | Server only. `change_log.seq` is the sync cursor *and* the audit trail. |

`srs_state` is per `(card_id, user_id)`: a shared knowledge base should not mean
shared learning progress.

## Open questions

Known gaps, roughly in the order they will start to hurt:

* **Authentication is a static token map** (`-tokens`, or `-dev-user` for local
  work). It needs real accounts with rotation and revocation before an instance
  is shared with people who do not all trust each other.
* **Authorization does not exist.** Every authenticated user receives every
  change. Scoping deltas per user or per notebook is a `WHERE` clause plus a
  decision about who may read what.
* **OPFS needs a web worker.** `SimpleOpfsFileSystem` requires synchronous
  access handles, which browsers only provide inside a dedicated worker, so the
  app currently falls back to the IndexedDB-backed VFS on the main thread. The
  fix is to move the database into a worker and talk to it over messages --
  worth doing, and not a protocol change.
* **Duplicate titles.** `nodes.title_key` is deliberately *not* unique: two
  offline devices creating "Spaced Repetition" would otherwise produce a batch
  that can never be applied. The UI should detect duplicates and offer a merge.
* **Rejected mutations are dropped** after being reported once. They belong in a
  local dead-letter table.
* **No full-text search.** The obvious answer is an FTS5 table derived locally
  on both sides, like `links`.
* **Clock trust.** See "What this protocol does not do" in
  [sync-protocol.md](sync-protocol.md).
* **No end-to-end test across a real browser.** The Go side is tested
  thoroughly and the pure-Dart logic is unit-tested, but the full loop
  (trigger → push → delta → local write) is only tested with a simulated
  client, not a real PWA.
