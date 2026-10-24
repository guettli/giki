# The sync protocol

One endpoint, one round trip: push the local outbox, pull everything new.

```
POST /api/v1/sync
Authorization: Bearer <token>
Content-Type: application/json
```

## Request

```json
{
  "device_id": "018f3c4e-7b2a-7c9d-8e1f-2a3b4c5d6e7f",
  "cursor": 41,
  "max_deltas": 500,
  "mutations": [
    {
      "client_seq": 7,
      "table": "nodes",
      "record_id": "018f3c4e-aaaa-7c9d-8e1f-2a3b4c5d6e7f",
      "op": "UPDATE",
      "updated_at": "2026-10-23T10:00:00.000Z",
      "payload": {
        "id": "018f3c4e-aaaa-7c9d-8e1f-2a3b4c5d6e7f",
        "title": "Leitner",
        "title_key": "leitner",
        "body": "Five boxes. See [[Spaced Repetition]].",
        "created_at": "2026-10-22T09:00:00.000Z",
        "created_by": "alice",
        "updated_at": "2026-10-23T10:00:00.000Z",
        "updated_by": "alice",
        "is_deleted": 0
      }
    }
  ]
}
```

* `device_id` is minted on first launch and stored in `sync_meta`. It is how
  the server avoids echoing a device's own changes back to it.
* `cursor` is the highest `change_log.seq` the client has already written
  locally. `0` means "I am empty, send me everything".
* `client_seq` is the local `sync_outbox.seq`. It is echoed back so each row
  can be acknowledged individually.
* `payload` is the row as the SQLite trigger built it. The server validates it
  against an allowlist of tables and columns
  (`internal/store/registry.go`); anything else is rejected.
* `updated_at` is the Last-Write-Wins clock: ISO-8601, UTC, exactly three
  decimals, so that string comparison is time comparison in SQL, Go and Dart
  alike. Other RFC3339 forms are accepted and normalized to it.

## Response

```json
{
  "cursor": 43,
  "results": [
    {"client_seq": 7, "record_id": "018f...", "status": "applied", "seq": 42}
  ],
  "changes": [
    {
      "seq": 43,
      "table": "cards",
      "record_id": "018f3c4e-bbbb-7c9d-8e1f-2a3b4c5d6e7f",
      "op": "INSERT",
      "updated_at": "2026-10-23T10:00:05.000Z",
      "payload": {"id": "018f3c4e-bbbb-...", "front": "Leitner box 3 interval?", "back": "7 days"},
      "actor_user_id": "bob",
      "origin_device_id": "018f3c4e-cccc-...",
      "applied_at": "2026-10-23T10:00:05.120Z"
    }
  ],
  "has_more": false,
  "server_time": "2026-10-23T10:00:06.000Z"
}
```

Each pushed mutation gets one of three verdicts:

| `status` | Meaning | What the client does |
| --- | --- | --- |
| `applied` | Stored and appended to the ChangeLog. | Drop it from the outbox. |
| `stale` | A version with an equal or newer `updated_at` already exists, so LWW discarded this one. Not an error. | Drop it from the outbox; the winning version arrives as a delta. |
| `rejected` | Malformed, unknown table or column, bad timestamp, mismatched id. | Drop it and surface it. Retrying unchanged cannot help -- it is a bug. |

`changes` are deltas, oldest first, to be applied in order. `has_more` means
the page was full and the client should sync again immediately.

## Invariants

These are the properties the implementation is built around. Breaking one of
them loses data quietly, which is why each has a test.

1. **A batch is atomic.** All mutations of one request are applied in a single
   transaction, so a client that retries after a network failure never has to
   reason about partial state. A `stale` or `rejected` verdict does not abort
   the batch; only infrastructure failures roll it back.
2. **The cursor only advances past deltas the client actually received.** It is
   never set to the server's head while deltas are still pending, and the head
   is read *before* the deltas so a concurrent commit cannot be skipped.
3. **Deltas and the cursor are committed together,** in one local transaction
   with `sync_mute` held. If the browser tab dies mid-write, both roll back and
   the same deltas arrive again.
4. **The outbox is cleared only after the deltas are committed.** If the tab
   dies in between, those mutations are pushed a second time and
   Last-Write-Wins makes the repeat a no-op. The reverse order would lose them.
5. **Settled rows are deleted by explicit `seq`,** never "everything up to the
   highest" -- the user keeps typing while a sync is in flight.
6. **A device never receives its own change as a delta.** The server filters on
   `origin_device_id`; the client's `sync_mute` guard is the second line of
   defence, for the writes it makes itself.
7. **The actor comes from the session, never from the payload.** An audit trail
   that records self-reported authorship is not an audit trail.
8. **Deletes are tombstones.** `is_deleted = 1` plus a new `updated_at`. Every
   column has a `DEFAULT`, so a tombstone that arrives before the row it
   deletes still applies -- it creates a placeholder the real `INSERT` fills in
   later, if that insert wins LWW.

## What this protocol does not do

* **No per-field merge.** Two devices editing the same page in the same minute:
  the later `updated_at` wins the whole row, and the loser's version is
  preserved only in the ChangeLog. Acceptable for a knowledge base, not for
  simultaneous prose editing.
* **No clock authority.** LWW trusts the client's clock. A device whose clock
  is hours ahead wins conflicts it should not. `server_time` is returned so the
  client can notice and warn; it does not yet.
* **No tie-break.** Two mutations with the exact same millisecond are resolved
  by arrival order at the server. Deterministic for a given server, arbitrary
  across one.
* **No partial sync.** Every client gets every change it is allowed to see.
  Per-notebook or per-user scoping would be a `WHERE` clause on the delta
  query, and a decision about who may read what -- neither exists yet.
* **No dead-letter queue.** A `rejected` mutation is reported once and dropped.
  It should be moved to a local table so it survives a reload.

## Attachments

An image or file is two things, synced two ways:

* the **`attachments` row** (page, file name, MIME type, size, `sha256`) is
  ordinary synced data: outbox, Last-Write-Wins, ChangeLog;
* the **bytes** are a content-addressed blob, never in the ChangeLog:

```
PUT /api/v1/blobs/{sha256}    body: raw bytes      -> 200 {"sha256", "size"}
GET /api/v1/blobs/{sha256}                         -> 200 raw bytes
```

The server checks that the bytes hash to the path (400 otherwise), caps a blob
at 10 MiB (413), and stores it once; repeating an upload is a no-op. Every
download is served as `application/octet-stream` with `Content-Disposition:
attachment`, `nosniff` and a sandbox CSP: the type lives in the synced row, and
user-uploaded HTML or SVG must never render on the app's origin.

Order is what keeps the halves consistent. A sync round **uploads pending blobs
first** and only then pushes the outbox, so no device ever receives a row whose
bytes the server lacks. After applying deltas it **fetches missing blobs**,
best effort: a page shows "not downloaded yet" and the next round retries.
Blobs live in SQLite on both sides (`blobs` table), so the server's database
file remains the whole backup. Removing an attachment tombstones the row; the
blob stays, since another row may share it.
