#!/bin/sh
# Downloads sqlite3.wasm into client/web/.
#
# The binary is not checked in: it is a build input, pinned here to the same
# release as the `sqlite3` package version in client/pubspec.yaml. Keep the two
# in step -- a mismatched wasm build is a runtime failure, not a build error.
set -eu

version=${SQLITE3_WASM_VERSION:-3.7.1}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/client/web/sqlite3.wasm"
url="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$version/sqlite3.wasm"

echo "fetching sqlite3.wasm $version"
if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --output "$target" "$url"
else
    wget --quiet --output-document "$target" "$url"
fi
echo "wrote client/web/sqlite3.wasm"
