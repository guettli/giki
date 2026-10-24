-- giki: isomorphic domain schema.
--
-- This file is applied VERBATIM on both sides:
--   * client: SQLite compiled to Wasm, stored in the Origin Private File System
--   * server: SQLite on disk, embedded in the single Go binary
--
-- Rules for every syncable table:
--   id          TEXT PRIMARY KEY -- UUIDv4/v7 minted by whoever creates the row,
--                                   so two offline clients never collide
--   created_at  TEXT NOT NULL    -- ISO-8601 UTC, millisecond precision
--   updated_at  TEXT NOT NULL    -- the Last-Write-Wins clock; lexicographic
--                                   comparison on this format == chronological
--   is_deleted  INTEGER NOT NULL -- tombstone. Rows are never hard-deleted,
--                                   otherwise a delete cannot be replicated.
--
-- Deliberately NO foreign key constraints on syncable tables: a delta batch can
-- legitimately deliver a card before the node it belongs to, and a strict FK
-- would reject the batch. Referential integrity is enforced in the UI and by
-- the server's validation layer, not by the storage engine.
--
-- For the same reason every column except the timestamps has a DEFAULT: a
-- tombstone can reach a replica before the row it deletes ever did, and that
-- delete still has to be applicable. The result is a placeholder row carrying
-- is_deleted = 1, which the real INSERT later fills in -- or does not, if it
-- lost the Last-Write-Wins comparison.

-- No PRAGMAs here: journal mode is a per-connection/per-deployment decision.
-- The server sets WAL in internal/store; the Wasm/OPFS client cannot use WAL
-- in every browser and sets its own.

CREATE TABLE IF NOT EXISTS users (
    id           TEXT    PRIMARY KEY,
    display_name TEXT    NOT NULL DEFAULT '',
    email        TEXT    NOT NULL DEFAULT '',
    created_at   TEXT    NOT NULL,
    updated_at   TEXT    NOT NULL,
    is_deleted   INTEGER NOT NULL DEFAULT 0
);

-- A node is one wiki page. `title_key` is the normalized (casefolded, trimmed)
-- title used to resolve [[WikiLinks]].
--
-- NOT unique on purpose: two clients may create "Spaced Repetition" while
-- offline. A UNIQUE index would make one of the two batches unapplyable
-- forever. Duplicates are surfaced in the UI as a merge suggestion instead.
CREATE TABLE IF NOT EXISTS nodes (
    id         TEXT    PRIMARY KEY,
    title      TEXT    NOT NULL DEFAULT '',
    title_key  TEXT    NOT NULL DEFAULT '',
    body       TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL,
    created_by TEXT    NOT NULL DEFAULT '',
    updated_at TEXT    NOT NULL,
    updated_by TEXT    NOT NULL DEFAULT '',
    is_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS nodes_title_key ON nodes (title_key) WHERE is_deleted = 0;
CREATE INDEX IF NOT EXISTS nodes_updated_at ON nodes (updated_at);

-- Flashcards. `node_id` may point at a node that does not exist (yet).
CREATE TABLE IF NOT EXISTS cards (
    id         TEXT    PRIMARY KEY,
    node_id    TEXT    NOT NULL DEFAULT '',
    front      TEXT    NOT NULL DEFAULT '',
    back       TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL,
    created_by TEXT    NOT NULL DEFAULT '',
    updated_at TEXT    NOT NULL,
    updated_by TEXT    NOT NULL DEFAULT '',
    is_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS cards_node_id ON cards (node_id) WHERE is_deleted = 0;

-- Spaced repetition state, one row per (card, user): learning progress is
-- personal, the knowledge base is shared.
CREATE TABLE IF NOT EXISTS srs_state (
    id               TEXT    PRIMARY KEY,
    card_id          TEXT    NOT NULL DEFAULT '',
    user_id          TEXT    NOT NULL DEFAULT '',
    box              INTEGER NOT NULL DEFAULT 1,  -- Leitner box / SM-2 stage
    interval_days    INTEGER NOT NULL DEFAULT 0,
    ease             REAL    NOT NULL DEFAULT 2.5,
    reps             INTEGER NOT NULL DEFAULT 0,
    lapses           INTEGER NOT NULL DEFAULT 0,
    due_at           TEXT    NOT NULL DEFAULT '',
    last_reviewed_at TEXT    NOT NULL DEFAULT '',
    created_at       TEXT    NOT NULL,
    updated_at       TEXT    NOT NULL,
    is_deleted       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS srs_state_due ON srs_state (user_id, due_at) WHERE is_deleted = 0;
CREATE INDEX IF NOT EXISTS srs_state_card_user ON srs_state (card_id, user_id);

-- Append-only review history. Rows are written once and never updated, so they
-- are conflict-free by construction.
CREATE TABLE IF NOT EXISTS review_log (
    id          TEXT    PRIMARY KEY,
    card_id     TEXT    NOT NULL DEFAULT '',
    user_id     TEXT    NOT NULL DEFAULT '',
    reviewed_at TEXT    NOT NULL DEFAULT '',
    rating      INTEGER NOT NULL DEFAULT 0,          -- 0 = again .. 3 = easy
    prev_box    INTEGER NOT NULL DEFAULT 0,
    next_box    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL,
    is_deleted  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS review_log_card ON review_log (card_id, reviewed_at);

-- A file or image attached to a node. Only the metadata syncs through the
-- outbox and the ChangeLog; the bytes are a content-addressed blob, uploaded
-- and fetched separately by `sha256` (lowercase hex). Content addressing makes
-- the blob immutable, so it needs no Last-Write-Wins of its own: an "edited"
-- file is a new attachment row pointing at a new hash.
CREATE TABLE IF NOT EXISTS attachments (
    id         TEXT    PRIMARY KEY,
    node_id    TEXT    NOT NULL DEFAULT '',
    sha256     TEXT    NOT NULL DEFAULT '',
    filename   TEXT    NOT NULL DEFAULT '',
    mime_type  TEXT    NOT NULL DEFAULT '',
    size       INTEGER NOT NULL DEFAULT 0,
    created_at TEXT    NOT NULL,
    created_by TEXT    NOT NULL DEFAULT '',
    updated_at TEXT    NOT NULL,
    updated_by TEXT    NOT NULL DEFAULT '',
    is_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS attachments_node_id ON attachments (node_id) WHERE is_deleted = 0;
CREATE INDEX IF NOT EXISTS attachments_sha256 ON attachments (sha256);

-- ---------------------------------------------------------------------------
-- Derived, NOT synced
-- ---------------------------------------------------------------------------

-- Wiki links extracted from nodes.body. Rebuilt locally whenever a body
-- changes, on both client and server, so it carries no sync columns and has no
-- outbox trigger. `target_node_id` is empty for a dangling link.
CREATE TABLE IF NOT EXISTS links (
    source_node_id  TEXT NOT NULL,
    target_title_key TEXT NOT NULL,
    target_node_id  TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (source_node_id, target_title_key)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS links_backlinks ON links (target_title_key);
