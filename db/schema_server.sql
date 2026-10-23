-- giki: server-only schema (applied after db/schema.sql).
--
-- The server has no outbox -- it is the convergence point, not a replica. What
-- it has instead is the global ChangeLog: the audit trail AND the delta feed
-- for every client, in one append-only table.

-- Every mutation the server accepts, in the order it accepted it.
--   seq              the global sync cursor. A client that has seen seq=N asks
--                    for "everything after N".
--   origin_device_id the device that pushed the change. Deltas are never sent
--                    back to their origin device, which is the second half of
--                    the echo-loop defence (the client's sync_mute is the first).
--   actor_user_id    who did it. This is the accountability column; it is taken
--                    from the authenticated session, never from the payload.
CREATE TABLE IF NOT EXISTS change_log (
    seq               INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name        TEXT    NOT NULL,
    record_id         TEXT    NOT NULL,
    op                TEXT    NOT NULL CHECK (op IN ('INSERT', 'UPDATE', 'DELETE')),
    payload           TEXT    NOT NULL,
    record_updated_at TEXT    NOT NULL,   -- the row's LWW clock
    actor_user_id     TEXT    NOT NULL,
    origin_device_id  TEXT    NOT NULL,
    applied_at        TEXT    NOT NULL    -- server wall clock
);
CREATE INDEX IF NOT EXISTS change_log_record ON change_log (table_name, record_id, seq);
CREATE INDEX IF NOT EXISTS change_log_actor ON change_log (actor_user_id, seq);

-- One row per client device, so a device can be audited, reset or revoked.
CREATE TABLE IF NOT EXISTS devices (
    id           TEXT    PRIMARY KEY,
    user_id      TEXT    NOT NULL,
    label        TEXT    NOT NULL DEFAULT '',
    last_cursor  INTEGER NOT NULL DEFAULT 0,  -- last cursor we handed out
    last_seen_at TEXT    NOT NULL,
    created_at   TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_user ON devices (user_id);
