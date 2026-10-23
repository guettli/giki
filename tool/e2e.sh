#!/bin/sh
# Runs the end-to-end test: a real browser, the real local SQLite-Wasm
# database, and a real giki server.
#
#   tool/e2e.sh
#
# It builds and starts the server, starts chromedriver, runs the test in
# headless Chrome, and tears everything down. On failure it prints the server
# and chromedriver logs, which is usually where the answer is.
#
# Note: flutter's web debug service binds a wildcard address, so this does not
# run inside sandboxes that forbid that (binding 0.0.0.0 fails with
# EADDRINUSE there). CI runners are fine.
#
# Environment:
#   CHROMEDRIVER          path to chromedriver (default: from PATH)
#   CHROME_EXECUTABLE     path to Chrome, honoured by flutter drive
#   GIKI_E2E_API_PORT     server port (default: first free from 8099)
#   GIKI_E2E_WEB_PORT     port the app is served on (default: first free from 8098)
#   GIKI_E2E_DRIVER_PORT  chromedriver port (default: first free from 4444)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
token=${GIKI_E2E_TOKEN:-e2e-token}
user=${GIKI_E2E_USER:-alice}
register_token=${GIKI_E2E_REGISTER_TOKEN:-e2e-register-token}
chromedriver=${CHROMEDRIVER:-chromedriver}

# Three ports have to be free, and one of them (the web port) has to be known
# before the server starts, because it goes into the CORS allowlist. Scan for
# unused ones rather than hardcoding: developer machines have things listening
# in the 8000s, and a collision here looks like a mysterious test failure.
listening_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '/^tcp/ {print $4}' | sed 's/.*://'
    fi
}

taken=$(listening_ports)

# pick_port BASE [PORT...]: the first free port from BASE upwards, skipping
# anything listening and any PORT given.
#
# The already-chosen ports have to be passed in: pick_port runs inside a
# command substitution, so anything it assigns is lost with its subshell, and
# two calls that only consulted $taken would hand out the same number twice.
pick_port() {
    candidate=$1
    shift
    while [ "$candidate" -lt 65000 ]; do
        if ! printf '%s\n' "$taken" | grep -qx "$candidate" &&
            ! printf '%s\n' "$@" | grep -qx "$candidate"; then
            echo "$candidate"
            return 0
        fi
        candidate=$((candidate + 1))
    done
    echo "no free port found from $1 upwards" >&2
    return 1
}

api_port=${GIKI_E2E_API_PORT:-$(pick_port 8099)}
web_port=${GIKI_E2E_WEB_PORT:-$(pick_port 8098 "$api_port")}
driver_port=${GIKI_E2E_DRIVER_PORT:-$(pick_port 4444 "$api_port" "$web_port")}

if [ "$api_port" = "$web_port" ] || [ "$api_port" = "$driver_port" ] ||
    [ "$web_port" = "$driver_port" ]; then
    echo "ports collide: api=$api_port web=$web_port chromedriver=$driver_port" >&2
    exit 1
fi

workdir=$(mktemp -d)
server_pid=''
driver_pid=''

cleanup() {
    status=$?
    trap - EXIT
    [ -n "$driver_pid" ] && kill "$driver_pid" 2>/dev/null || true
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        # Let it finish writing: the last lines of the log are the ones worth
        # reading when something went wrong.
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
        echo "--- server log ---" >&2
        cat "$workdir/server.log" 2>/dev/null >&2 || true
        echo "--- chromedriver log (tail) ---" >&2
        tail -n 30 "$workdir/chromedriver.log" 2>/dev/null >&2 || true
    fi
    rm -rf "$workdir"
    exit "$status"
}
trap cleanup EXIT INT TERM

wait_for() {
    url=$1
    name=$2
    attempt=0
    while [ "$attempt" -lt 150 ]; do
        if curl --fail --silent --output /dev/null "$url"; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.2
    done
    echo "$name did not come up at $url" >&2
    return 1
}

if [ ! -f "$root/client/web/sqlite3.wasm" ]; then
    "$root/tool/fetch-sqlite-wasm.sh"
fi

echo "ports: api=$api_port web=$web_port chromedriver=$driver_port"
echo "building the server"
(cd "$root" && go build -o "$workdir/giki-server" ./cmd/giki-server)

echo "starting the server on 127.0.0.1:$api_port"
# The app is served from a different port than the API, so the browser sends a
# cross-origin request and the server has to allow that one origin. Both
# spellings of localhost are listed because the two are different origins to a
# browser, and which one the page ends up on depends on flutter drive.
# Passkeys are enabled with localhost as the relying party: browsers treat
# http://localhost as a secure context, so WebAuthn is available there without
# a certificate. The test cannot complete a ceremony (that needs a virtual
# authenticator driven over CDP, which the test inside the page cannot reach),
# but it does check that the options the server produces are the options the
# client can digest -- which is where the two sides drift apart.
"$workdir/giki-server" \
    -db "$workdir/giki.sqlite" \
    -addr "127.0.0.1:$api_port" \
    -tokens "$token:$user" \
    -cors-origin "http://localhost:$web_port,http://127.0.0.1:$web_port" \
    -passkey-domain localhost \
    -passkey-origin "http://localhost:$web_port,http://127.0.0.1:$web_port" \
    -register-token "$register_token" \
    >"$workdir/server.log" 2>&1 &
server_pid=$!
wait_for "http://127.0.0.1:$api_port/healthz" "the giki server"

echo "starting chromedriver on port $driver_port"
"$chromedriver" --port="$driver_port" >"$workdir/chromedriver.log" 2>&1 &
driver_pid=$!
wait_for "http://127.0.0.1:$driver_port/status" "chromedriver"

echo "running the test in headless chrome"
cd "$root/client"
# --timeout because flutter drive defaults to waiting forever: if Chrome never
# connects (a JS exception in main(), a debug-service handshake that fails) the
# run would otherwise hang with a server and a chromedriver still alive.
flutter drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/sync_flow_test.dart \
    --device-id=web-server \
    --browser-name=chrome \
    --headless \
    --web-port="$web_port" \
    --driver-port="$driver_port" \
    --timeout="${GIKI_E2E_TIMEOUT:-600}" \
    --dart-define=GIKI_E2E_SERVER="http://127.0.0.1:$api_port" \
    --dart-define=GIKI_E2E_TOKEN="$token" \
    --dart-define=GIKI_E2E_USER="$user" \
    --dart-define=GIKI_E2E_REGISTER_TOKEN="$register_token"

# flutter drive has exited 0 before now without having run anything. The server
# logs one line per sync round trip, and this test makes several, so an empty
# log means the browser never reached the API -- a pass that proves nothing.
syncs=$(grep -c 'msg=sync' "$workdir/server.log" || true)
if [ "${syncs:-0}" -lt 4 ]; then
    echo "the server handled only ${syncs:-0} sync requests: the test did not really run" >&2
    exit 1
fi

# Same reasoning for the passkey phases: "All tests passed" is an aggregate,
# and a suite that silently skipped them would still print it. The server logs
# one line per registration ceremony it starts.
ceremonies=$(grep -c 'msg="passkey registration begun"' "$workdir/server.log" || true)
if [ "${ceremonies:-0}" -lt 1 ]; then
    echo "the passkey phases did not reach the server: the test did not really run" >&2
    exit 1
fi
echo "ok: the server handled $syncs sync requests and $ceremonies passkey ceremonies"
