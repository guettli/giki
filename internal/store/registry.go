package store

// The registry is giki's allowlist: the only tables and columns a sync batch
// may ever touch. The Outbox pattern deliberately ships generic JSON, which
// means the server must decide for itself what is writable -- a client payload
// never gets to name a table or a column that is not listed here.
//
// Column lists must match db/schema.sql. TestRegistryMatchesSchema enforces
// that, so a schema change that forgets this file fails CI.

// Table describes one syncable table.
type Table struct {
	Name string
	// Columns in schema order. Must contain "id", "updated_at" and
	// "is_deleted"; those three carry the sync contract.
	Columns []string
}

// Has reports whether col is writable on this table.
func (t Table) Has(col string) bool {
	for _, c := range t.Columns {
		if c == col {
			return true
		}
	}
	return false
}

var registry = map[string]Table{
	"users": {Name: "users", Columns: []string{
		"id", "display_name", "email", "created_at", "updated_at", "is_deleted",
	}},
	"nodes": {Name: "nodes", Columns: []string{
		"id", "title", "title_key", "body", "created_at", "created_by",
		"updated_at", "updated_by", "is_deleted",
	}},
	"cards": {Name: "cards", Columns: []string{
		"id", "node_id", "front", "back", "created_at", "created_by",
		"updated_at", "updated_by", "is_deleted",
	}},
	"srs_state": {Name: "srs_state", Columns: []string{
		"id", "card_id", "user_id", "box", "interval_days", "ease", "reps",
		"lapses", "due_at", "last_reviewed_at", "created_at", "updated_at",
		"is_deleted",
	}},
	"review_log": {Name: "review_log", Columns: []string{
		"id", "card_id", "user_id", "reviewed_at", "rating", "prev_box",
		"next_box", "created_at", "updated_at", "is_deleted",
	}},
}

// LookupTable returns the registry entry for name.
func LookupTable(name string) (Table, bool) {
	t, ok := registry[name]
	return t, ok
}

// SyncableTables lists every table that participates in sync.
func SyncableTables() []string {
	names := make([]string, 0, len(registry))
	for name := range registry {
		names = append(names, name)
	}
	return names
}
