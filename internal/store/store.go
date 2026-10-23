// Package store owns giki's server-side SQLite database and the rules for
// applying a client's sync batch to it.
package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	_ "modernc.org/sqlite" // pure-Go driver: no cgo, so the server stays a single static binary

	"github.com/guettli/giki/db"
)

// TimeFormat is giki's only timestamp format: ISO-8601, UTC, exactly three
// decimals. The format is chosen so that lexicographic string comparison is
// chronological comparison -- Last-Write-Wins can then be decided in SQL, in
// SQLite triggers and in Go without any of them agreeing on a time library.
const TimeFormat = "2006-01-02T15:04:05.000Z07:00"

// Now returns the current time in TimeFormat.
func Now() string { return time.Now().UTC().Format(TimeFormat) }

// CanonicalClock parses a client timestamp and re-renders it in TimeFormat.
// Clients that send an offset ("+02:00") or extra precision are normalized
// here, because LWW compares these values as strings.
func CanonicalClock(s string) (string, error) {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return "", fmt.Errorf("timestamp %q is not RFC3339: %w", s, err)
	}
	return t.UTC().Format(TimeFormat), nil
}

// Store is the server's database handle.
type Store struct {
	DB *sql.DB
}

// Open opens (and if needed creates) the database at path and applies the
// shared and server schemas. Use ":memory:" for tests.
func Open(path string) (*Store, error) {
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=foreign_keys(0)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)"
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	// One connection: every write path here is a short transaction, and a
	// single connection removes SQLITE_BUSY from the picture entirely. If read
	// throughput ever matters, split into a write handle and a read pool --
	// not before.
	sqlDB.SetMaxOpenConns(1)

	for _, schema := range []string{db.Shared, db.Server} {
		if _, err := sqlDB.Exec(schema); err != nil {
			sqlDB.Close()
			return nil, fmt.Errorf("apply schema: %w", err)
		}
	}
	return &Store{DB: sqlDB}, nil
}

// Close closes the underlying database.
func (s *Store) Close() error { return s.DB.Close() }

// Cursor is the current head of the ChangeLog: the sync cursor a fully
// up-to-date client holds.
func (s *Store) Cursor(ctx context.Context) (int64, error) {
	var cursor sql.NullInt64
	err := s.DB.QueryRowContext(ctx, `SELECT MAX(seq) FROM change_log`).Scan(&cursor)
	if err != nil {
		return 0, fmt.Errorf("read cursor: %w", err)
	}
	return cursor.Int64, nil
}

// TouchDevice records that a device synced, and which cursor it was handed.
func (s *Store) TouchDevice(ctx context.Context, deviceID, userID string, cursor int64) error {
	now := Now()
	_, err := s.DB.ExecContext(ctx, `
		INSERT INTO devices (id, user_id, label, last_cursor, last_seen_at, created_at)
		VALUES (?, ?, '', ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
			user_id      = excluded.user_id,
			last_cursor  = excluded.last_cursor,
			last_seen_at = excluded.last_seen_at`,
		deviceID, userID, cursor, now, now)
	if err != nil {
		return fmt.Errorf("touch device %s: %w", deviceID, err)
	}
	return nil
}
