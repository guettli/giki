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
| `links` | no | Derived from `nodes.body` on the client, by the Markdown parser that renders the page, so backlinks list exactly the pages that show a link. Rebuilt on every write, so it carries no sync columns. The server does not maintain its copy. |
| `sync_outbox`, `sync_mute`, `sync_meta` | no | Client only. |
| `change_log`, `devices` | no | Server only. `change_log.seq` is the sync cursor *and* the audit trail. |
| `passkey_users`, `passkeys`, `passkey_ceremonies`, `api_sessions` | no | Server only. Public keys are not secret, but they are not the user's knowledge base either, and the sync protocol exists to replicate the latter. Keeping them out of the registry means a client cannot push a row into them. |

`srs_state` is per `(card_id, user_id)`: a shared knowledge base should not mean
shared learning progress.

## Open questions

Known gaps, roughly in the order they will start to hurt:

* **Authentication is passkeys** (WebAuthn), with static tokens kept for
  scripts. A ceremony issues an opaque bearer session rather than setting a
  cookie: the sync API is a POST with a JSON body, so a cookie would make it
  reachable from any page the user visits, while a bearer token cannot be read
  cross-origin. Only the SHA-256 of a session is stored -- and likewise of an
  in-flight ceremony handle, which is the sole authorization for the
  unauthenticated `register/finish` -- so a leaked database hands out neither
  working sessions nor half-finished registrations.

  What is still missing is session management worth the name: a user cannot
  list or revoke their sessions, only the one device they are holding. Removing
  a passkey does revoke the sessions that passkey created.
* **Authorization does not exist.** Every authenticated user receives every
  change. Scoping deltas per user or per notebook is a `WHERE` clause plus a
  decision about who may read what. This is why registering a new account
  needs `-register-token`: until there is authorization, letting anyone sign
  up is letting anyone read everything.
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
* **The passkey ceremonies are not exercised in a browser *in CI*.** They are
  tested against a real software authenticator in Go
  (`internal/syncapi/authapi_test.go`), and the browser test checks that the
  options the server produces are the options the client can convert. The
  ceremony itself can now be run end to end by hand --
  `tool/explore.mjs passkey "Register a passkey"` attaches Chrome's virtual
  authenticator over the DevTools protocol -- but that is an exploratory tool,
  not a test: nothing asserts, and CI does not run it.
* **Clock trust.** See "What this protocol does not do" in
  [sync-protocol.md](sync-protocol.md).
* **The end-to-end test covers the loop, not the UI.** `tool/e2e.sh` drives
  the real app in headless Chrome against a real server, so the full path
  (trigger → outbox → push → delta → local write, including the echo guard and
  both sides of Last-Write-Wins) is checked on every push. What it does not do
  is drive the interface: it asserts one widget smoke test and otherwise works
  through the repositories and the sync service.
* **The OPFS path is not what CI exercises.** The test runs in a browser tab,
  where OPFS is unavailable, so it covers the IndexedDB fallback. Testing the
  OPFS path needs the worker above.
