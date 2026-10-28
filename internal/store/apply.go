package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/guettli/giki/internal/wikilink"
)

// Mutation is one row-level change as the client's sync_outbox produced it.
// Payload stays raw JSON the whole way: the SQLite trigger built it with
// json_object(), the server validates it against the registry and writes it
// back out to the ChangeLog unchanged. Nothing in between needs a per-table
// Go struct, which is exactly why giki speaks JSON and not Protobuf.
type Mutation struct {
	ClientSeq int64           `json:"client_seq"`
	Table     string          `json:"table"`
	RecordID  string          `json:"record_id"`
	Op        string          `json:"op"`
	UpdatedAt string          `json:"updated_at"`
	Payload   json.RawMessage `json:"payload"`
}

// Status is the outcome of applying one Mutation.
type Status string

const (
	// StatusApplied: the row was written and appended to the ChangeLog.
	StatusApplied Status = "applied"
	// StatusStale: a newer (or equal) version already exists, so
	// Last-Write-Wins discarded this one. Not an error -- the client drops it
	// from its outbox and will receive the winning version as a delta.
	StatusStale Status = "stale"
	// StatusRejected: malformed or not allowed. The client must not retry
	// as-is; it is a bug or an attack, either way it belongs in the log.
	StatusRejected Status = "rejected"
)

// Result reports what happened to one Mutation.
type Result struct {
	ClientSeq int64  `json:"client_seq"`
	RecordID  string `json:"record_id"`
	Status    Status `json:"status"`
	// Seq is the ChangeLog sequence assigned to an applied mutation.
	Seq int64 `json:"seq,omitempty"`
	// Reason explains a rejection or a staleness verdict.
	Reason string `json:"reason,omitempty"`
}

// Actor is the authenticated origin of a batch. It comes from the session,
// never from the payload -- otherwise the audit trail would be self-reported.
type Actor struct {
	UserID   string
	DeviceID string
}

// ErrRejected marks a mutation that must not be retried unchanged.
var ErrRejected = errors.New("mutation rejected")

// Change is one entry of the global ChangeLog, as sent back to clients as a
// delta and as read by the audit trail UI.
type Change struct {
	Seq            int64           `json:"seq"`
	Table          string          `json:"table"`
	RecordID       string          `json:"record_id"`
	Op             string          `json:"op"`
	UpdatedAt      string          `json:"updated_at"`
	Payload        json.RawMessage `json:"payload"`
	ActorUserID    string          `json:"actor_user_id"`
	OriginDeviceID string          `json:"origin_device_id"`
	AppliedAt      string          `json:"applied_at"`
}

// ApplyBatch applies every mutation of one push in a single transaction: a
// client's batch either lands completely or not at all, so a client that
// retries after a network failure never has to reason about partial state.
//
// A rejected or stale mutation does not abort the batch -- it is reported per
// mutation in the returned results. Only infrastructure failures roll back.
func (s *Store) ApplyBatch(ctx context.Context, actor Actor, muts []Mutation) ([]Result, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after a successful Commit

	results := make([]Result, 0, len(muts))
	for _, m := range muts {
		res, err := s.applyOne(ctx, tx, actor, m)
		if err != nil && !errors.Is(err, ErrRejected) {
			return nil, err
		}
		results = append(results, res)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit: %w", err)
	}
	return results, nil
}

func (s *Store) applyOne(ctx context.Context, tx *sql.Tx, actor Actor, m Mutation) (Result, error) {
	res := Result{ClientSeq: m.ClientSeq, RecordID: m.RecordID}
	reject := func(format string, args ...any) (Result, error) {
		res.Status = StatusRejected
		res.Reason = fmt.Sprintf(format, args...)
		return res, ErrRejected
	}

	table, ok := LookupTable(m.Table)
	if !ok {
		return reject("unknown table %q", m.Table)
	}
	if m.Op != "INSERT" && m.Op != "UPDATE" && m.Op != "DELETE" {
		return reject("unknown op %q", m.Op)
	}
	if m.RecordID == "" {
		return reject("empty record_id")
	}
	clock, err := CanonicalClock(m.UpdatedAt)
	if err != nil {
		return reject("%s", err)
	}

	row, err := decodeRow(m.Payload)
	if err != nil {
		return reject("%s", err)
	}
	if id, _ := row["id"].(string); id != "" && id != m.RecordID {
		return reject("payload id %q does not match record_id %q", id, m.RecordID)
	}
	for col := range row {
		if !table.Has(col) {
			return reject("column %q is not syncable on %s", col, table.Name)
		}
	}

	// A DELETE is a tombstone, never a real DELETE: a row that is gone cannot
	// be replicated to a device that is still offline.
	if m.Op == "DELETE" {
		row = map[string]any{"id": m.RecordID, "is_deleted": 1}
	}
	row["id"] = m.RecordID
	row["updated_at"] = clock
	if _, ok := row["created_at"]; !ok {
		row["created_at"] = clock
	}
	// The server, not the client, decides how a title normalizes -- otherwise
	// two clients could disagree about which page a [[link]] points at.
	if table.Name == "nodes" {
		if title, ok := row["title"].(string); ok {
			row["title_key"] = wikilink.NormalizeTitle(title)
		}
	}

	// An attachment row is accepted only once its bytes are here. Clients
	// upload blobs before pushing rows, so this never fires for a working
	// client -- it makes "no device ever sees a row without bytes" a property
	// of the server rather than a promise of every client. Tombstones pass:
	// deleting needs no bytes.
	if deleted, _ := row["is_deleted"].(int64); table.Name == "attachments" && m.Op != "DELETE" && deleted != 1 {
		key, _ := row["sha256"].(string)
		if !ValidBlobKey(key) {
			return reject("attachment sha256 %q is not a lowercase hex sha256", key)
		}
		var present int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM blobs WHERE sha256 = ?`, key).Scan(&present); err != nil {
			return res, fmt.Errorf("look up blob %s: %w", key, err)
		}
		if present == 0 {
			return reject("blob %s has not been uploaded", key)
		}
	}

	// --- Last-Write-Wins -----------------------------------------------
	// Equal timestamps keep the row that is already stored. That is
	// deterministic for a given server, which is what matters; it does mean a
	// same-millisecond conflict is resolved by arrival order.
	var stored string
	err = tx.QueryRowContext(ctx,
		fmt.Sprintf(`SELECT updated_at FROM %q WHERE id = ?`, table.Name), m.RecordID).Scan(&stored)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// new row, nothing to compare
	case err != nil:
		return res, fmt.Errorf("read %s/%s: %w", table.Name, m.RecordID, err)
	case stored >= clock:
		res.Status = StatusStale
		res.Reason = fmt.Sprintf("stored version %s is not older than %s", stored, clock)
		return res, nil
	}

	if err := upsert(ctx, tx, table, row); err != nil {
		return res, err
	}
	if table.Name == "nodes" {
		if body, ok := row["body"].(string); ok {
			if err := rebuildLinks(ctx, tx, m.RecordID, body); err != nil {
				return res, err
			}
		}
	}

	// The payload written to the ChangeLog is the normalized row, not the
	// client's bytes: what the audit trail shows is what the database holds.
	normalized, err := json.Marshal(row)
	if err != nil {
		return res, fmt.Errorf("marshal normalized row: %w", err)
	}
	seq, err := appendChangeLog(ctx, tx, table.Name, m.RecordID, m.Op, normalized, clock, actor)
	if err != nil {
		return res, err
	}
	res.Status, res.Seq = StatusApplied, seq
	return res, nil
}

// decodeRow decodes a trigger-built JSON object. json.Number keeps integers
// exact: SQLite INTEGER columns must not round-trip through float64.
func decodeRow(payload json.RawMessage) (map[string]any, error) {
	if len(payload) == 0 {
		return nil, errors.New("empty payload")
	}
	dec := json.NewDecoder(strings.NewReader(string(payload)))
	dec.UseNumber()
	var row map[string]any
	if err := dec.Decode(&row); err != nil {
		return nil, fmt.Errorf("payload is not a JSON object: %w", err)
	}
	if row == nil {
		return nil, errors.New("payload is null")
	}
	for col, v := range row {
		if n, ok := v.(json.Number); ok {
			if i, err := n.Int64(); err == nil {
				row[col] = i
			} else {
				f, err := n.Float64()
				if err != nil {
					return nil, fmt.Errorf("column %q: %w", col, err)
				}
				row[col] = f
			}
			continue
		}
		switch v.(type) {
		case string, bool, nil:
		default:
			return nil, fmt.Errorf("column %q has unsupported type %T", col, v)
		}
	}
	return row, nil
}

// upsert writes exactly the columns present in row. Columns the client did not
// send keep their stored value on update, and their schema default on insert.
func upsert(ctx context.Context, tx *sql.Tx, table Table, row map[string]any) error {
	cols := make([]string, 0, len(row))
	for col := range row {
		cols = append(cols, col)
	}
	sort.Strings(cols) // stable SQL text -> SQLite can reuse the prepared statement

	placeholders := make([]string, len(cols))
	assignments := make([]string, 0, len(cols))
	args := make([]any, len(cols))
	for i, col := range cols {
		placeholders[i] = "?"
		args[i] = row[col]
		if col != "id" {
			assignments = append(assignments, fmt.Sprintf("%q = excluded.%q", col, col))
		}
	}
	quoted := make([]string, len(cols))
	for i, col := range cols {
		quoted[i] = fmt.Sprintf("%q", col)
	}

	query := fmt.Sprintf(
		`INSERT INTO %q (%s) VALUES (%s) ON CONFLICT (id) DO UPDATE SET %s`,
		table.Name, strings.Join(quoted, ", "), strings.Join(placeholders, ", "),
		strings.Join(assignments, ", "))
	if _, err := tx.ExecContext(ctx, query, args...); err != nil {
		return fmt.Errorf("upsert %s: %w", table.Name, err)
	}
	return nil
}

// rebuildLinks refreshes the derived link index for one node. links is local
// to each database and carries no sync columns, so this is a plain rewrite.
func rebuildLinks(ctx context.Context, tx *sql.Tx, nodeID, body string) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM links WHERE source_node_id = ?`, nodeID); err != nil {
		return fmt.Errorf("clear links of %s: %w", nodeID, err)
	}
	for _, key := range wikilink.Parse(body) {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO links (source_node_id, target_title_key, target_node_id)
			VALUES (?, ?, COALESCE((SELECT id FROM nodes WHERE title_key = ? AND is_deleted = 0 LIMIT 1), ''))
			ON CONFLICT (source_node_id, target_title_key) DO NOTHING`,
			nodeID, key, key)
		if err != nil {
			return fmt.Errorf("link %s -> %s: %w", nodeID, key, err)
		}
	}
	return nil
}

func appendChangeLog(ctx context.Context, tx *sql.Tx, table, recordID, op string, payload []byte, clock string, actor Actor) (int64, error) {
	result, err := tx.ExecContext(ctx, `
		INSERT INTO change_log (table_name, record_id, op, payload, record_updated_at,
		                        actor_user_id, origin_device_id, applied_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		table, recordID, op, string(payload), clock, actor.UserID, actor.DeviceID, Now())
	if err != nil {
		return 0, fmt.Errorf("append change_log: %w", err)
	}
	seq, err := result.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("change_log seq: %w", err)
	}
	return seq, nil
}

// Changes returns the ChangeLog entries after afterSeq, skipping those that
// originated on excludeDevice. Skipping the origin device is the server half of
// the echo-loop defence; the client's sync_mute table is the other half.
//
// The bool reports whether more entries are waiting beyond limit, so a client
// that has been offline for a month syncs in pages instead of one huge body.
func (s *Store) Changes(ctx context.Context, afterSeq int64, excludeDevice string, limit int) ([]Change, bool, error) {
	if limit <= 0 {
		limit = 500
	}
	rows, err := s.DB.QueryContext(ctx, `
		SELECT seq, table_name, record_id, op, payload, record_updated_at,
		       actor_user_id, origin_device_id, applied_at
		FROM change_log
		WHERE seq > ? AND origin_device_id <> ?
		ORDER BY seq
		LIMIT ?`, afterSeq, excludeDevice, limit+1)
	if err != nil {
		return nil, false, fmt.Errorf("read changes: %w", err)
	}
	defer rows.Close()

	changes := make([]Change, 0, limit)
	hasMore := false
	for rows.Next() {
		if len(changes) == limit {
			hasMore = true
			break
		}
		var c Change
		var payload string
		if err := rows.Scan(&c.Seq, &c.Table, &c.RecordID, &c.Op, &payload,
			&c.UpdatedAt, &c.ActorUserID, &c.OriginDeviceID, &c.AppliedAt); err != nil {
			return nil, false, fmt.Errorf("scan change: %w", err)
		}
		c.Payload = json.RawMessage(payload)
		changes = append(changes, c)
	}
	if err := rows.Err(); err != nil {
		return nil, false, fmt.Errorf("iterate changes: %w", err)
	}
	return changes, hasMore, nil
}

// RecordHistory returns the audit trail of one record, oldest first: who
// changed it, when, and to what. With more than limit entries it returns the
// newest limit of them -- the recent past is what a reader of a long-lived
// page is after, and the oldest 200 versions of it are not.
func (s *Store) RecordHistory(ctx context.Context, table, recordID string, limit int) ([]Change, error) {
	if _, ok := LookupTable(table); !ok {
		return nil, fmt.Errorf("%w: unknown table %q", ErrRejected, table)
	}
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.DB.QueryContext(ctx, `
		SELECT * FROM (
			SELECT seq, table_name, record_id, op, payload, record_updated_at,
			       actor_user_id, origin_device_id, applied_at
			FROM change_log
			WHERE table_name = ? AND record_id = ?
			ORDER BY seq DESC
			LIMIT ?
		) ORDER BY seq`, table, recordID, limit)
	if err != nil {
		return nil, fmt.Errorf("read history: %w", err)
	}
	defer rows.Close()

	var history []Change
	for rows.Next() {
		var c Change
		var payload string
		if err := rows.Scan(&c.Seq, &c.Table, &c.RecordID, &c.Op, &payload,
			&c.UpdatedAt, &c.ActorUserID, &c.OriginDeviceID, &c.AppliedAt); err != nil {
			return nil, fmt.Errorf("scan history: %w", err)
		}
		c.Payload = json.RawMessage(payload)
		history = append(history, c)
	}
	return history, rows.Err()
}
