-- giki: client-only schema (applied after db/schema.sql).
--
-- Holds the outbox that the background sync worker drains, plus the mute switch
-- that stops server deltas from being echoed straight back to the server.

-- Every local mutation lands here, in commit order. `seq` is the only
-- autoincrement ID in giki -- it is purely local and never leaves the device
-- as an identifier, so it cannot collide with anything.
CREATE TABLE IF NOT EXISTS sync_outbox (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name TEXT    NOT NULL,
    record_id  TEXT    NOT NULL,
    op         TEXT    NOT NULL CHECK (op IN ('INSERT', 'UPDATE', 'DELETE')),
    payload    TEXT    NOT NULL,   -- full row as JSON, built by the trigger
    updated_at TEXT    NOT NULL,   -- copy of the row's LWW clock
    created_at TEXT    NOT NULL
);

-- Non-empty == "we are currently writing server deltas into the local DB".
-- Every trigger below checks it, which is how the echo loop is broken without
-- disabling or dropping triggers at runtime.
CREATE TABLE IF NOT EXISTS sync_mute (
    token TEXT PRIMARY KEY
);

-- last_sync_cursor, device_id, current user, schema version, ...
CREATE TABLE IF NOT EXISTS sync_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- Outbox triggers
-- ---------------------------------------------------------------------------
--
-- One INSERT/UPDATE/DELETE trigger per syncable table. The payload is built
-- with json_object() so the wire format is produced by the database itself --
-- no ORM, no marshalling layer, nothing that can drift from the schema.
--
-- The `WHERE NOT EXISTS (SELECT 1 FROM sync_mute)` guard is what makes the
-- pattern "zero magic": the statement simply inserts nothing while deltas are
-- being applied. SQLite does not allow a subquery in a trigger's WHEN clause,
-- so the guard lives in the body.
--
-- DELETE triggers exist for completeness. Normal deletion is a tombstone
-- (`UPDATE ... SET is_deleted = 1`), which flows through the UPDATE trigger;
-- a hard DELETE is only used by local maintenance code.

CREATE TRIGGER IF NOT EXISTS users_outbox_insert AFTER INSERT ON users BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'users', NEW.id, 'INSERT',
           json_object('id', NEW.id, 'display_name', NEW.display_name,
                       'email', NEW.email, 'created_at', NEW.created_at,
                       'updated_at', NEW.updated_at, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS users_outbox_update AFTER UPDATE ON users BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'users', NEW.id, 'UPDATE',
           json_object('id', NEW.id, 'display_name', NEW.display_name,
                       'email', NEW.email, 'created_at', NEW.created_at,
                       'updated_at', NEW.updated_at, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS users_outbox_delete AFTER DELETE ON users BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'users', OLD.id, 'DELETE', json_object('id', OLD.id),
           OLD.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS nodes_outbox_insert AFTER INSERT ON nodes BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'nodes', NEW.id, 'INSERT',
           json_object('id', NEW.id, 'title', NEW.title, 'title_key', NEW.title_key,
                       'body', NEW.body, 'created_at', NEW.created_at,
                       'created_by', NEW.created_by, 'updated_at', NEW.updated_at,
                       'updated_by', NEW.updated_by, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS nodes_outbox_update AFTER UPDATE ON nodes BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'nodes', NEW.id, 'UPDATE',
           json_object('id', NEW.id, 'title', NEW.title, 'title_key', NEW.title_key,
                       'body', NEW.body, 'created_at', NEW.created_at,
                       'created_by', NEW.created_by, 'updated_at', NEW.updated_at,
                       'updated_by', NEW.updated_by, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS nodes_outbox_delete AFTER DELETE ON nodes BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'nodes', OLD.id, 'DELETE', json_object('id', OLD.id),
           OLD.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS cards_outbox_insert AFTER INSERT ON cards BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'cards', NEW.id, 'INSERT',
           json_object('id', NEW.id, 'node_id', NEW.node_id, 'front', NEW.front,
                       'back', NEW.back, 'created_at', NEW.created_at,
                       'created_by', NEW.created_by, 'updated_at', NEW.updated_at,
                       'updated_by', NEW.updated_by, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS cards_outbox_update AFTER UPDATE ON cards BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'cards', NEW.id, 'UPDATE',
           json_object('id', NEW.id, 'node_id', NEW.node_id, 'front', NEW.front,
                       'back', NEW.back, 'created_at', NEW.created_at,
                       'created_by', NEW.created_by, 'updated_at', NEW.updated_at,
                       'updated_by', NEW.updated_by, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS cards_outbox_delete AFTER DELETE ON cards BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'cards', OLD.id, 'DELETE', json_object('id', OLD.id),
           OLD.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS srs_state_outbox_insert AFTER INSERT ON srs_state BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'srs_state', NEW.id, 'INSERT',
           json_object('id', NEW.id, 'card_id', NEW.card_id, 'user_id', NEW.user_id,
                       'box', NEW.box, 'interval_days', NEW.interval_days,
                       'ease', NEW.ease, 'reps', NEW.reps, 'lapses', NEW.lapses,
                       'due_at', NEW.due_at, 'last_reviewed_at', NEW.last_reviewed_at,
                       'created_at', NEW.created_at, 'updated_at', NEW.updated_at,
                       'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS srs_state_outbox_update AFTER UPDATE ON srs_state BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'srs_state', NEW.id, 'UPDATE',
           json_object('id', NEW.id, 'card_id', NEW.card_id, 'user_id', NEW.user_id,
                       'box', NEW.box, 'interval_days', NEW.interval_days,
                       'ease', NEW.ease, 'reps', NEW.reps, 'lapses', NEW.lapses,
                       'due_at', NEW.due_at, 'last_reviewed_at', NEW.last_reviewed_at,
                       'created_at', NEW.created_at, 'updated_at', NEW.updated_at,
                       'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS srs_state_outbox_delete AFTER DELETE ON srs_state BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'srs_state', OLD.id, 'DELETE', json_object('id', OLD.id),
           OLD.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS review_log_outbox_insert AFTER INSERT ON review_log BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'review_log', NEW.id, 'INSERT',
           json_object('id', NEW.id, 'card_id', NEW.card_id, 'user_id', NEW.user_id,
                       'reviewed_at', NEW.reviewed_at, 'rating', NEW.rating,
                       'prev_box', NEW.prev_box, 'next_box', NEW.next_box,
                       'created_at', NEW.created_at, 'updated_at', NEW.updated_at,
                       'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS review_log_outbox_update AFTER UPDATE ON review_log BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'review_log', NEW.id, 'UPDATE',
           json_object('id', NEW.id, 'card_id', NEW.card_id, 'user_id', NEW.user_id,
                       'reviewed_at', NEW.reviewed_at, 'rating', NEW.rating,
                       'prev_box', NEW.prev_box, 'next_box', NEW.next_box,
                       'created_at', NEW.created_at, 'updated_at', NEW.updated_at,
                       'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS review_log_outbox_delete AFTER DELETE ON review_log BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'review_log', OLD.id, 'DELETE', json_object('id', OLD.id),
           OLD.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS attachments_outbox_insert AFTER INSERT ON attachments BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'attachments', NEW.id, 'INSERT',
           json_object('id', NEW.id, 'node_id', NEW.node_id, 'sha256', NEW.sha256,
                       'filename', NEW.filename, 'mime_type', NEW.mime_type,
                       'size', NEW.size, 'created_at', NEW.created_at,
                       'created_by', NEW.created_by, 'updated_at', NEW.updated_at,
                       'updated_by', NEW.updated_by, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS attachments_outbox_update AFTER UPDATE ON attachments BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'attachments', NEW.id, 'UPDATE',
           json_object('id', NEW.id, 'node_id', NEW.node_id, 'sha256', NEW.sha256,
                       'filename', NEW.filename, 'mime_type', NEW.mime_type,
                       'size', NEW.size, 'created_at', NEW.created_at,
                       'created_by', NEW.created_by, 'updated_at', NEW.updated_at,
                       'updated_by', NEW.updated_by, 'is_deleted', NEW.is_deleted),
           NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

CREATE TRIGGER IF NOT EXISTS attachments_outbox_delete AFTER DELETE ON attachments BEGIN
    INSERT INTO sync_outbox (table_name, record_id, op, payload, updated_at, created_at)
    SELECT 'attachments', OLD.id, 'DELETE', json_object('id', OLD.id),
           OLD.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM sync_mute);
END;

-- ---------------------------------------------------------------------------
-- Attachment bytes (local, NOT synced through the outbox)
-- ---------------------------------------------------------------------------
--
-- The local copy of every blob this device has, keyed by SHA-256. `uploaded`
-- is 0 until the server confirmed it holds the bytes; the sync worker uploads
-- those BEFORE pushing the outbox, so no other device ever learns of an
-- attachment whose bytes the server does not have.
--
-- Deliberately a rowid table: SQLite's update hook, which is how the UI hears
-- that bytes arrived, does not fire for WITHOUT ROWID tables.
--
-- Bytes of other devices' attachments are fetched on demand, when a page that
-- shows them is opened -- not eagerly: the knowledge base is shared, and every
-- tab holding every file would not scale.
CREATE TABLE IF NOT EXISTS blobs (
    sha256     TEXT    PRIMARY KEY,
    size       INTEGER NOT NULL,
    data       BLOB    NOT NULL,
    uploaded   INTEGER NOT NULL DEFAULT 0,
    created_at TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS blobs_pending ON blobs (sha256) WHERE uploaded = 0;
