// Package db carries giki's SQL schema as embedded files.
//
// The same .sql files are applied by the Go server and copied verbatim into the
// Flutter client's assets by tool/sync-schema.sh, so both sides demonstrably
// run the same DDL -- that is what "isomorphic schema" means here, and CI
// fails if the copies drift apart.
package db

import "embed"

//go:embed schema.sql schema_client.sql schema_server.sql
var FS embed.FS

func mustRead(name string) string {
	b, err := FS.ReadFile(name)
	if err != nil {
		panic("db: embedded schema missing: " + name)
	}
	return string(b)
}

var (
	// Shared is applied on client and server alike: the domain tables.
	Shared = mustRead("schema.sql")
	// Client adds the outbox, the mute switch and the triggers.
	Client = mustRead("schema_client.sql")
	// Server adds the global ChangeLog and the device registry.
	Server = mustRead("schema_server.sql")
)
