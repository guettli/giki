package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"sort"
	"testing"

	"github.com/guettli/giki/db"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// openClientDB builds a client-shaped database: the shared schema plus the
// outbox and its triggers. Used to prove the triggers and the server-side
// registry describe the same columns.
func openClientDB(t *testing.T) *sql.DB {
	t.Helper()
	sqlDB, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "client.sqlite"))
	if err != nil {
		t.Fatalf("open client db: %v", err)
	}
	t.Cleanup(func() { sqlDB.Close() })
	for _, schema := range []string{db.Shared, db.Client} {
		if _, err := sqlDB.Exec(schema); err != nil {
			t.Fatalf("apply client schema: %v", err)
		}
	}
	return sqlDB
}

func node(id, title, body, clock string) Mutation {
	payload, _ := json.Marshal(map[string]any{
		"id": id, "title": title, "title_key": title, "body": body,
		"created_at": clock, "updated_at": clock, "is_deleted": 0,
	})
	return Mutation{Table: "nodes", RecordID: id, Op: "UPDATE", UpdatedAt: clock, Payload: payload}
}

func TestCanonicalClock(t *testing.T) {
	for in, want := range map[string]string{
		"2026-10-23T10:00:00.000Z":      "2026-10-23T10:00:00.000Z",
		"2026-10-23T12:00:00.000+02:00": "2026-10-23T10:00:00.000Z",
		"2026-10-23T10:00:00Z":          "2026-10-23T10:00:00.000Z",
	} {
		got, err := CanonicalClock(in)
		if err != nil {
			t.Fatalf("CanonicalClock(%q): %v", in, err)
		}
		if got != want {
			t.Errorf("CanonicalClock(%q) = %q, want %q", in, got, want)
		}
	}
	if _, err := CanonicalClock("yesterday"); err == nil {
		t.Error("CanonicalClock should reject non-RFC3339 input")
	}
}

// TestRegistryMatchesSchema is the guard that keeps the Go allowlist and the
// SQL schema from drifting apart.
func TestRegistryMatchesSchema(t *testing.T) {
	st := openTestStore(t)
	for _, name := range SyncableTables() {
		table, _ := LookupTable(name)
		rows, err := st.DB.Query(`SELECT name FROM pragma_table_info(?) ORDER BY cid`, name)
		if err != nil {
			t.Fatalf("pragma_table_info(%s): %v", name, err)
		}
		var columns []string
		for rows.Next() {
			var col string
			if err := rows.Scan(&col); err != nil {
				t.Fatalf("scan column: %v", err)
			}
			columns = append(columns, col)
		}
		rows.Close()
		if len(columns) == 0 {
			t.Fatalf("table %s does not exist in db/schema.sql", name)
		}
		if got, want := joinSorted(table.Columns), joinSorted(columns); got != want {
			t.Errorf("registry for %s = %s, schema has %s", name, got, want)
		}
		for _, required := range []string{"id", "updated_at", "is_deleted"} {
			if !table.Has(required) {
				t.Errorf("table %s is missing the sync column %q", name, required)
			}
		}
	}
}

// TestTriggerPayloadsMatchRegistry runs the real client triggers and checks
// that what they put on the wire is exactly what the server accepts.
func TestTriggerPayloadsMatchRegistry(t *testing.T) {
	clientDB := openClientDB(t)
	clock := "2026-10-23T10:00:00.000Z"
	inserts := map[string]string{
		"users":      `INSERT INTO users (id, created_at, updated_at) VALUES ('u1', ?, ?)`,
		"nodes":      `INSERT INTO nodes (id, title, title_key, created_at, updated_at) VALUES ('n1', 'T', 't', ?, ?)`,
		"cards":      `INSERT INTO cards (id, created_at, updated_at) VALUES ('c1', ?, ?)`,
		"srs_state":  `INSERT INTO srs_state (id, card_id, user_id, due_at, created_at, updated_at) VALUES ('s1', 'c1', 'u1', '2026-10-24T00:00:00.000Z', ?, ?)`,
		"review_log": `INSERT INTO review_log (id, card_id, user_id, reviewed_at, rating, created_at, updated_at) VALUES ('r1', 'c1', 'u1', '2026-10-23T10:00:00.000Z', 2, ?, ?)`,
	}
	if len(inserts) != len(SyncableTables()) {
		t.Fatalf("this test covers %d tables, but %d are syncable", len(inserts), len(SyncableTables()))
	}
	for name, stmt := range inserts {
		if _, err := clientDB.Exec(stmt, clock, clock); err != nil {
			t.Fatalf("insert into %s: %v", name, err)
		}
		var payload string
		err := clientDB.QueryRow(
			`SELECT payload FROM sync_outbox WHERE table_name = ? ORDER BY seq DESC LIMIT 1`, name).Scan(&payload)
		if err != nil {
			t.Fatalf("no outbox row for %s: %v", name, err)
		}
		row, err := decodeRow(json.RawMessage(payload))
		if err != nil {
			t.Fatalf("trigger payload for %s is not decodable: %v", name, err)
		}
		keys := make([]string, 0, len(row))
		for key := range row {
			keys = append(keys, key)
		}
		table, _ := LookupTable(name)
		if got, want := joinSorted(keys), joinSorted(table.Columns); got != want {
			t.Errorf("trigger payload for %s has %s, registry allows %s", name, got, want)
		}
	}
}

func TestMuteStopsEcho(t *testing.T) {
	clientDB := openClientDB(t)
	clock := "2026-10-23T10:00:00.000Z"
	if _, err := clientDB.Exec(`INSERT INTO sync_mute (token) VALUES ('applying-deltas')`); err != nil {
		t.Fatalf("mute: %v", err)
	}
	if _, err := clientDB.Exec(
		`INSERT INTO nodes (id, title, title_key, created_at, updated_at) VALUES ('n1', 'T', 't', ?, ?)`,
		clock, clock); err != nil {
		t.Fatalf("muted insert: %v", err)
	}
	var muted int
	if err := clientDB.QueryRow(`SELECT COUNT(*) FROM sync_outbox`).Scan(&muted); err != nil {
		t.Fatalf("count outbox: %v", err)
	}
	if muted != 0 {
		t.Fatalf("outbox has %d rows while muted, want 0", muted)
	}

	if _, err := clientDB.Exec(`DELETE FROM sync_mute`); err != nil {
		t.Fatalf("unmute: %v", err)
	}
	if _, err := clientDB.Exec(`UPDATE nodes SET body = 'local edit', updated_at = ? WHERE id = 'n1'`,
		"2026-10-23T10:01:00.000Z"); err != nil {
		t.Fatalf("local edit: %v", err)
	}
	var unmuted int
	if err := clientDB.QueryRow(`SELECT COUNT(*) FROM sync_outbox`).Scan(&unmuted); err != nil {
		t.Fatalf("count outbox: %v", err)
	}
	if unmuted != 1 {
		t.Fatalf("outbox has %d rows after unmuting, want 1", unmuted)
	}
}

func TestApplyBatchLastWriteWins(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	alice := Actor{UserID: "alice", DeviceID: "dev-a"}
	bob := Actor{UserID: "bob", DeviceID: "dev-b"}

	results, err := st.ApplyBatch(ctx, alice, []Mutation{node("n1", "Leitner", "first", "2026-10-23T10:00:00.000Z")})
	if err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	if results[0].Status != StatusApplied {
		t.Fatalf("first write: status = %s (%s), want applied", results[0].Status, results[0].Reason)
	}

	// Bob wins: his clock is later.
	results, err = st.ApplyBatch(ctx, bob, []Mutation{node("n1", "Leitner", "bob wins", "2026-10-23T11:00:00.000Z")})
	if err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	if results[0].Status != StatusApplied {
		t.Fatalf("later write: status = %s (%s), want applied", results[0].Status, results[0].Reason)
	}

	// Alice's offline edit is older and must lose -- without aborting her batch.
	results, err = st.ApplyBatch(ctx, alice, []Mutation{
		node("n1", "Leitner", "stale offline edit", "2026-10-23T10:30:00.000Z"),
		node("n2", "SM-2", "fresh", "2026-10-23T12:00:00.000Z"),
	})
	if err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	if results[0].Status != StatusStale {
		t.Errorf("stale write: status = %s, want stale", results[0].Status)
	}
	if results[1].Status != StatusApplied {
		t.Errorf("second mutation: status = %s (%s), want applied", results[1].Status, results[1].Reason)
	}

	var body string
	if err := st.DB.QueryRow(`SELECT body FROM nodes WHERE id = 'n1'`).Scan(&body); err != nil {
		t.Fatalf("read node: %v", err)
	}
	if body != "bob wins" {
		t.Errorf("body = %q, want %q", body, "bob wins")
	}
}

func TestApplyBatchRejections(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	actor := Actor{UserID: "alice", DeviceID: "dev-a"}
	clock := "2026-10-23T10:00:00.000Z"

	bad := []struct {
		name string
		mut  Mutation
	}{
		{"unknown table", Mutation{Table: "secrets", RecordID: "x", Op: "UPDATE", UpdatedAt: clock, Payload: json.RawMessage(`{"id":"x"}`)}},
		{"unknown op", Mutation{Table: "nodes", RecordID: "x", Op: "TRUNCATE", UpdatedAt: clock, Payload: json.RawMessage(`{"id":"x"}`)}},
		{"empty record id", Mutation{Table: "nodes", RecordID: "", Op: "UPDATE", UpdatedAt: clock, Payload: json.RawMessage(`{"id":""}`)}},
		{"bad clock", Mutation{Table: "nodes", RecordID: "x", Op: "UPDATE", UpdatedAt: "yesterday", Payload: json.RawMessage(`{"id":"x"}`)}},
		{"id mismatch", Mutation{Table: "nodes", RecordID: "x", Op: "UPDATE", UpdatedAt: clock, Payload: json.RawMessage(`{"id":"y"}`)}},
		{"unknown column", Mutation{Table: "nodes", RecordID: "x", Op: "UPDATE", UpdatedAt: clock, Payload: json.RawMessage(`{"id":"x","rowid":3}`)}},
		{"nested object", Mutation{Table: "nodes", RecordID: "x", Op: "UPDATE", UpdatedAt: clock, Payload: json.RawMessage(`{"id":"x","body":{"nope":1}}`)}},
		{"not an object", Mutation{Table: "nodes", RecordID: "x", Op: "UPDATE", UpdatedAt: clock, Payload: json.RawMessage(`"x"`)}},
		{"empty payload", Mutation{Table: "nodes", RecordID: "x", Op: "UPDATE", UpdatedAt: clock}},
	}
	for _, tc := range bad {
		t.Run(tc.name, func(t *testing.T) {
			results, err := st.ApplyBatch(ctx, actor, []Mutation{tc.mut})
			if err != nil {
				t.Fatalf("ApplyBatch returned a hard error: %v", err)
			}
			if results[0].Status != StatusRejected {
				t.Fatalf("status = %s, want rejected", results[0].Status)
			}
			if results[0].Reason == "" {
				t.Error("rejection has no reason")
			}
		})
	}
	// Nothing was written and nothing was logged.
	var logged int
	if err := st.DB.QueryRow(`SELECT COUNT(*) FROM change_log`).Scan(&logged); err != nil {
		t.Fatalf("count change_log: %v", err)
	}
	if logged != 0 {
		t.Errorf("change_log has %d entries after only rejections, want 0", logged)
	}
}

func TestTombstoneAndHistory(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	actor := Actor{UserID: "alice", DeviceID: "dev-a"}

	if _, err := st.ApplyBatch(ctx, actor, []Mutation{node("n1", "Leitner", "body", "2026-10-23T10:00:00.000Z")}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	results, err := st.ApplyBatch(ctx, actor, []Mutation{{
		Table: "nodes", RecordID: "n1", Op: "DELETE",
		UpdatedAt: "2026-10-23T11:00:00.000Z", Payload: json.RawMessage(`{"id":"n1"}`),
	}})
	if err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	if results[0].Status != StatusApplied {
		t.Fatalf("delete: status = %s (%s), want applied", results[0].Status, results[0].Reason)
	}

	// The row must still be there, tombstoned -- a hard delete could not be
	// replicated to a device that is still offline.
	var isDeleted int
	var title string
	if err := st.DB.QueryRow(`SELECT is_deleted, title FROM nodes WHERE id = 'n1'`).Scan(&isDeleted, &title); err != nil {
		t.Fatalf("read tombstone: %v", err)
	}
	if isDeleted != 1 {
		t.Errorf("is_deleted = %d, want 1", isDeleted)
	}
	if title != "Leitner" {
		t.Errorf("title = %q, want the row to survive the tombstone", title)
	}

	history, err := st.RecordHistory(ctx, "nodes", "n1", 0)
	if err != nil {
		t.Fatalf("RecordHistory: %v", err)
	}
	if len(history) != 2 {
		t.Fatalf("history has %d entries, want 2", len(history))
	}
	if history[0].Op != "UPDATE" || history[1].Op != "DELETE" {
		t.Errorf("history ops = %s, %s; want UPDATE, DELETE", history[0].Op, history[1].Op)
	}
	for i, entry := range history {
		if entry.ActorUserID != "alice" {
			t.Errorf("history[%d].ActorUserID = %q, want alice", i, entry.ActorUserID)
		}
	}
	if _, err := st.RecordHistory(ctx, "change_log", "n1", 0); err == nil {
		t.Error("RecordHistory should refuse a table that is not syncable")
	}
}

func TestChangesSkipOriginDevice(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	alice := Actor{UserID: "alice", DeviceID: "dev-a"}
	bob := Actor{UserID: "bob", DeviceID: "dev-b"}

	if _, err := st.ApplyBatch(ctx, alice, []Mutation{node("n1", "A", "a", "2026-10-23T10:00:00.000Z")}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	if _, err := st.ApplyBatch(ctx, bob, []Mutation{node("n2", "B", "b", "2026-10-23T10:01:00.000Z")}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}

	changes, hasMore, err := st.Changes(ctx, 0, "dev-a", 10)
	if err != nil {
		t.Fatalf("Changes: %v", err)
	}
	if hasMore {
		t.Error("hasMore = true, want false")
	}
	if len(changes) != 1 || changes[0].RecordID != "n2" {
		t.Fatalf("dev-a got %d changes (%+v), want only bob's n2", len(changes), changes)
	}

	// Paging: one entry at a time, with has_more set.
	changes, hasMore, err = st.Changes(ctx, 0, "dev-c", 1)
	if err != nil {
		t.Fatalf("Changes: %v", err)
	}
	if len(changes) != 1 || !hasMore {
		t.Fatalf("paged read returned %d changes, hasMore=%v; want 1, true", len(changes), hasMore)
	}
	changes, hasMore, err = st.Changes(ctx, changes[0].Seq, "dev-c", 1)
	if err != nil {
		t.Fatalf("Changes: %v", err)
	}
	if len(changes) != 1 || hasMore {
		t.Fatalf("second page returned %d changes, hasMore=%v; want 1, false", len(changes), hasMore)
	}
}

func TestApplyBatchDerivesLinks(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	actor := Actor{UserID: "alice", DeviceID: "dev-a"}

	if _, err := st.ApplyBatch(ctx, actor, []Mutation{
		node("n1", "Spaced Repetition", "see [[Leitner]] and [[SM-2]]", "2026-10-23T10:00:00.000Z"),
		node("n2", "Leitner", "a box system", "2026-10-23T10:01:00.000Z"),
	}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}

	var targets []string
	rows, err := st.DB.Query(`SELECT target_title_key FROM links WHERE source_node_id = 'n1' ORDER BY target_title_key`)
	if err != nil {
		t.Fatalf("read links: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			t.Fatalf("scan link: %v", err)
		}
		targets = append(targets, key)
	}
	if got, want := joinSorted(targets), "leitner,sm-2"; got != want {
		t.Errorf("links of n1 = %s, want %s", got, want)
	}

	// Editing the body replaces the derived links rather than adding to them.
	if _, err := st.ApplyBatch(ctx, actor, []Mutation{
		node("n1", "Spaced Repetition", "only [[Leitner]] now", "2026-10-23T12:00:00.000Z"),
	}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	var count int
	if err := st.DB.QueryRow(`SELECT COUNT(*) FROM links WHERE source_node_id = 'n1'`).Scan(&count); err != nil {
		t.Fatalf("count links: %v", err)
	}
	if count != 1 {
		t.Errorf("links of n1 = %d, want 1 after the edit", count)
	}
}

func TestApplyBatchNormalizesTitleKey(t *testing.T) {
	st := openTestStore(t)
	payload, _ := json.Marshal(map[string]any{
		"id": "n1", "title": "  Spaced   Repetition ", "title_key": "WRONG",
		"created_at": "2026-10-23T10:00:00.000Z", "updated_at": "2026-10-23T10:00:00.000Z",
	})
	if _, err := st.ApplyBatch(context.Background(), Actor{UserID: "alice", DeviceID: "dev-a"},
		[]Mutation{{Table: "nodes", RecordID: "n1", Op: "INSERT",
			UpdatedAt: "2026-10-23T10:00:00.000Z", Payload: payload}}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	var key string
	if err := st.DB.QueryRow(`SELECT title_key FROM nodes WHERE id = 'n1'`).Scan(&key); err != nil {
		t.Fatalf("read title_key: %v", err)
	}
	if key != "spaced repetition" {
		t.Errorf("title_key = %q, want the server's normalization", key)
	}
}

func TestCursorAndTouchDevice(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	cursor, err := st.Cursor(ctx)
	if err != nil {
		t.Fatalf("Cursor: %v", err)
	}
	if cursor != 0 {
		t.Errorf("empty database cursor = %d, want 0", cursor)
	}
	if _, err := st.ApplyBatch(ctx, Actor{UserID: "alice", DeviceID: "dev-a"},
		[]Mutation{node("n1", "A", "a", "2026-10-23T10:00:00.000Z")}); err != nil {
		t.Fatalf("ApplyBatch: %v", err)
	}
	if cursor, err = st.Cursor(ctx); err != nil || cursor != 1 {
		t.Errorf("Cursor = %d (err %v), want 1", cursor, err)
	}

	if err := st.TouchDevice(ctx, "dev-a", "alice", 1); err != nil {
		t.Fatalf("TouchDevice: %v", err)
	}
	if err := st.TouchDevice(ctx, "dev-a", "alice", 7); err != nil {
		t.Fatalf("TouchDevice again: %v", err)
	}
	var stored int64
	var devices int
	if err := st.DB.QueryRow(`SELECT COUNT(*), MAX(last_cursor) FROM devices`).Scan(&devices, &stored); err != nil {
		t.Fatalf("read devices: %v", err)
	}
	if devices != 1 || stored != 7 {
		t.Errorf("devices = %d with cursor %d, want 1 device at cursor 7", devices, stored)
	}
}

func joinSorted(values []string) string {
	copied := append([]string(nil), values...)
	sort.Strings(copied)
	out := ""
	for i, v := range copied {
		if i > 0 {
			out += ","
		}
		out += v
	}
	return out
}
