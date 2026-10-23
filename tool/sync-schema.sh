#!/bin/sh
# Copies the SQL schema into the Flutter client's assets.
#
# db/*.sql is the single source of truth: the Go server embeds those files and
# the client bundles these copies. Run this after every schema change and
# commit the result.
#
#   tool/sync-schema.sh          copy
#   tool/sync-schema.sh --check  fail if the copies are out of date (used in CI)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/db"
dst="$root/client/assets/db"

# The client applies the shared schema and the outbox triggers. schema_server.sql
# stays out of the browser bundle: the ChangeLog lives on the server only.
files="schema.sql schema_client.sql"

if [ "${1:-}" = "--check" ]; then
    status=0
    for name in $files; do
        if ! cmp -s "$src/$name" "$dst/$name"; then
            echo "out of date: client/assets/db/$name" >&2
            echo "run tool/sync-schema.sh and commit the result" >&2
            status=1
        fi
    done
    exit $status
fi

mkdir -p "$dst"
for name in $files; do
    cp "$src/$name" "$dst/$name"
    echo "copied $name"
done
