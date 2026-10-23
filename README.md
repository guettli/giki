# giki

Local-first wiki and spaced repetition, in one app.

[![CI](https://github.com/guettli/giki/actions/workflows/ci.yml/badge.svg)](https://github.com/guettli/giki/actions/workflows/ci.yml)

Write down what you are learning, link it the way a wiki does, and let the
parts worth memorizing come back as flashcards. The app runs from a SQLite
database inside your browser, so it opens instantly and works with no network
at all. When a server is configured, changes sync in the background and every
edit is recorded in an audit log that says who changed what, and when.

## Status

**Early.** The Go server, the shared SQLite schema and the sync protocol work
and are covered by tests. The Flutter client is a working skeleton: it stores
pages and cards locally, derives backlinks, schedules reviews and talks to the
server, but it has not been through a real design pass, and the OPFS fast path
still needs a web worker (see [docs/architecture.md](docs/architecture.md)).

## What it does

* **Wiki-style linking.** Write `[[Another Page]]` anywhere. Links resolve by
  title, so you can link to a page that does not exist yet -- following the
  link creates it. Every page shows its backlinks, which is how context
  accumulates without anyone maintaining it.
* **Spaced repetition.** Flashcards on a Leitner box ladder. Scheduling state
  is per user, so a shared knowledge base does not mean shared progress.
* **Offline by default.** The local database is the source of truth. Reads and
  writes never wait for the network; sync is a background detail.
* **Multi-user with an audit trail.** Every accepted change is appended to a
  server-side ChangeLog with its author, its device and its timestamp. In a
  shared knowledge base, "who wrote this and when" is not a nice-to-have.

## How it works

```
   Browser (PWA)                                 Server (one static binary)
┌──────────────────────────┐                   ┌──────────────────────────────┐
│  Flutter Web UI          │                   │  Go, net/http                │
│        ↓ plain SQL       │                   │        ↓                     │
│  SQLite (Wasm) ──────────│                   │  LWW apply + validation      │
│    ↓ AFTER INSERT/       │   POST /api/v1/   │        ↓                     │
│      UPDATE/DELETE       │       sync        │  SQLite (same schema)        │
│  sync_outbox  ───────────┼──── mutations ───▶│        ↓                     │
│                          │                   │  change_log (audit + feed)   │
│  local writes  ◀─────────┼──── deltas ───────│                              │
│  (triggers muted)        │                   │                              │
└──────────────────────────┘                   └──────────────────────────────┘
```

The client never calls a "save" API. It writes to its local SQLite database,
and triggers on every syncable table copy the row into `sync_outbox` as JSON,
built by `json_object()` in SQL. A background worker drains that outbox, posts
it, and writes the server's deltas back into the local database -- with a row
in `sync_mute`, which makes the triggers skip those writes so they are not
echoed back on the next sync.

Conflicts are resolved by Last-Write-Wins on `updated_at`. Deletions are
tombstones (`is_deleted = 1`), because a row that is really gone cannot be
replicated to a device that is still offline. Primary keys are UUIDv7, minted
by whichever device created the row, so two offline devices never collide.

The full protocol, including its failure modes and what it deliberately does
not do, is in [docs/sync-protocol.md](docs/sync-protocol.md).

### Why JSON over REST, and not gRPC

* Browsers do not expose HTTP/2 trailers, so gRPC from a web app needs
  grpc-web plus a proxy in front of the server. That is a lot of moving parts
  for one endpoint.
* The outbox payload is generic by design: a trigger builds whatever columns
  its table has. Protobuf would carry that as an opaque string or a
  `google.protobuf.Struct`, which gives up the strong typing that was the
  reason to use Protobuf in the first place. In Go it is a `json.RawMessage`.
* A sync batch can be read in the browser's Network tab, as it is.

### Why no CRDT

CRDTs solve a harder problem than this one: concurrent editing of the *same
sentence*. For a personal or small-team knowledge base, Last-Write-Wins on
whole rows plus a complete audit trail is enough -- and it fits in a file you
can read in one sitting, which matters more for a self-hosted tool than
theoretical elegance. If character-level merging is ever needed, it belongs in
the `nodes.body` column alone, not in the sync layer.

## Quick start

The toolchain is pinned in `mise.toml` ([mise](https://mise.jdx.dev)):

```sh
mise install                   # Go and Flutter, at the versions CI uses
```

Flutter brings its own Dart SDK, so `dart` comes from that install.

### Server

```sh
go build ./cmd/giki-server
./giki-server -db giki.sqlite -tokens "s3cret:alice,hunter2:bob"
```

`-tokens` maps bearer tokens to user ids; those ids are what the audit trail
records. For local hacking, `-dev-user alice` authenticates every request as
`alice` and logs a warning saying so.

```sh
curl localhost:8080/healthz
```

### Client

```sh
tool/fetch-sqlite-wasm.sh      # downloads client/web/sqlite3.wasm (not checked in)
cd client
flutter pub get
flutter run -d chrome          # or: flutter build web --release
```

Then open **Settings** in the app and enter the server URL, a bearer token and
your user id. Without them the app is simply local-only.

## Repository layout

| Path | What is in it |
| --- | --- |
| `db/` | The SQL schema. `schema.sql` is applied on both sides, `schema_client.sql` adds the outbox and its triggers, `schema_server.sql` adds the ChangeLog. |
| `cmd/giki-server/` | The server binary: flags, logging, graceful shutdown. |
| `internal/store/` | SQLite access, the table allowlist, and the Last-Write-Wins apply logic. |
| `internal/syncapi/` | The HTTP endpoints and the wire format. |
| `internal/auth/` | Bearer tokens to user ids. |
| `internal/wikilink/` | `[[WikiLink]]` parsing, mirrored in Dart. |
| `client/` | The Flutter Web PWA. |
| `tool/` | `sync-schema.sh` copies the schema into the client's assets; `fetch-sqlite-wasm.sh` downloads the SQLite Wasm build. |
| `docs/` | Architecture and protocol notes, including the open questions. |

## Development

```sh
go test ./...                  # server, schema and trigger behaviour
cd client && flutter test      # timestamps, ids, scheduling, link parsing, protocol parsing
tool/sync-schema.sh --check    # client schema copies are in step with db/
```

`db/schema.sql` is the single source of truth for the shared tables. After
changing it, update the column lists in `internal/store/registry.go` and the
`json_object()` calls in `db/schema_client.sql`, then run
`tool/sync-schema.sh`. Tests fail if any of the three drift apart, which is the
point: the client's triggers, the server's allowlist and the schema have to
describe the same columns or sync quietly loses data.

## License

[Apache-2.0](LICENSE).
