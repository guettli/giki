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

-- ---------------------------------------------------------------------------
-- Passkeys (server only)
-- ---------------------------------------------------------------------------
--
-- None of this syncs. A public key is not a secret, but it is not the user's
-- knowledge base either, and the sync protocol exists to replicate the latter.
-- Keeping these tables out of the registry means a client can never push a row
-- into them: the allowlist in internal/store/registry.go is the whole
-- vocabulary of the sync API.

-- The WebAuthn view of a user, which is not the same as the app's `users` row.
--
-- `handle` is the opaque user handle the authenticator stores alongside the
-- credential. It is random rather than the user id, because the handle travels
-- to the authenticator and back and the spec is explicit that it must not be
-- something displayed to anyone.
CREATE TABLE IF NOT EXISTS passkey_users (
    user_id      TEXT PRIMARY KEY,
    handle       TEXT NOT NULL UNIQUE,   -- base64url, 32 random bytes
    display_name TEXT NOT NULL DEFAULT '',
    created_at   TEXT NOT NULL
);

-- One row per registered authenticator. A user may have several: a phone, a
-- laptop, a hardware key. Deleting the last one locks the user out, which is
-- why the handler refuses to.
CREATE TABLE IF NOT EXISTS passkeys (
    id           TEXT PRIMARY KEY,       -- base64url credential ID
    user_id      TEXT NOT NULL,
    label        TEXT NOT NULL DEFAULT '',
    -- The whole webauthn.Credential as JSON: public key, transports, AAGUID,
    -- sign count. Stored whole because the library owns its shape, and a
    -- column per field would have to be migrated every time it changes.
    credential   TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    last_used_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS passkeys_user ON passkeys (user_id);

-- In-flight ceremonies. A WebAuthn ceremony is two requests, and the challenge
-- from the first must be remembered to verify the second.
--
-- In the database rather than in memory on purpose: the Deployment rolls with
-- strategy Recreate, and a user who happened to be registering during a deploy
-- would otherwise get an error with no explanation.
CREATE TABLE IF NOT EXISTS passkey_ceremonies (
    id         TEXT PRIMARY KEY,         -- opaque handle held by the client
    kind       TEXT NOT NULL CHECK (kind IN ('register', 'login')),
    user_id    TEXT NOT NULL DEFAULT '',
    session    TEXT NOT NULL,            -- webauthn.SessionData as JSON
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);

-- Bearer sessions issued by a successful ceremony.
--
-- Only the SHA-256 of the token is stored. A session token is a password
-- equivalent: a leaked database (or a backup, or a stray `SELECT *` in a log)
-- must not hand anybody a working session.
CREATE TABLE IF NOT EXISTS api_sessions (
    token_sha256 TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL,
    passkey_id   TEXT NOT NULL DEFAULT '',
    label        TEXT NOT NULL DEFAULT '',
    created_at   TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    expires_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS api_sessions_user ON api_sessions (user_id);

-- Attachment bytes, keyed by their SHA-256 (lowercase hex). Kept in SQLite so
-- the single database file stays the whole backup. Write-once: the server
-- verifies the hash on upload, so a row can never hold other bytes than its
-- key names, and a repeated upload is a no-op.
CREATE TABLE IF NOT EXISTS blobs (
    sha256     TEXT    PRIMARY KEY,
    size       INTEGER NOT NULL,
    data       BLOB    NOT NULL,
    created_by TEXT    NOT NULL,
    created_at TEXT    NOT NULL
) WITHOUT ROWID;
