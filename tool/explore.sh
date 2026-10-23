#!/bin/sh
# Starts (or stops) a disposable giki for exploratory testing: a server with a
# throwaway database, the built PWA on the same origin, and a headless Chrome
# with its debugging port open for tool/explore.mjs to drive.
#
#   tool/explore.sh start     # build if needed, launch, print the session
#   tool/explore.sh status
#   tool/explore.sh stop      # kill everything, delete the database
#
# Everything lives under .explore/ (gitignored), so a session leaves no trace
# in the repo and the next one starts from an empty knowledge base.
#
# Environment:
#   CHROME_EXECUTABLE   path to Chrome (default: google-chrome, then chromium)
#   GIKI_EXPLORE_PORT   server port (default: first free from 8110)
#   GIKI_EXPLORE_CDP    Chrome debugging port (default: first free from 9222)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state="$root/.explore"
token=explore-token
user=explorer
register_token=explore-register-token

listening_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '/^tcp/ {print $4}' | sed 's/.*://'
    fi
}

pick_port() {
    candidate=$1
    shift
    taken=$(listening_ports)
    while [ "$candidate" -lt 65000 ]; do
        if ! printf '%s\n' "$taken" | grep -qx "$candidate" &&
            ! printf '%s\n' "$@" | grep -qx "$candidate"; then
            echo "$candidate"
            return 0
        fi
        candidate=$((candidate + 1))
    done
    echo "no free port from $1 upwards" >&2
    return 1
}

find_chrome() {
    if [ -n "${CHROME_EXECUTABLE:-}" ]; then
        echo "$CHROME_EXECUTABLE"
        return 0
    fi
    for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    echo "no Chrome found; set CHROME_EXECUTABLE" >&2
    return 1
}

stop_session() {
    for name in chrome server; do
        if [ -f "$state/$name.pid" ]; then
            pid=$(cat "$state/$name.pid")
            kill "$pid" 2>/dev/null || true
            rm -f "$state/$name.pid"
        fi
    done
    # The database goes too: an exploratory session that starts from the last
    # one's leftovers is not reproducible, and reproducibility is the only
    # thing that turns a finding into a bug report.
    rm -rf "$state/giki.sqlite" "$state/giki.sqlite-wal" "$state/giki.sqlite-shm" \
        "$state/chrome" "$state/session.env"
    echo "session stopped"
}

status_session() {
    if [ ! -f "$state/session.env" ]; then
        echo "no session running"
        return 1
    fi
    # shellcheck disable=SC1091
    . "$state/session.env"
    printf 'url            %s\n' "$GIKI_EXPLORE_URL"
    printf 'cdp            http://127.0.0.1:%s\n' "$GIKI_EXPLORE_CDP_PORT"
    printf 'database       %s\n' "$GIKI_EXPLORE_DB"
    printf 'server log     %s\n' "$GIKI_EXPLORE_SERVER_LOG"
    printf 'static token   %s (user %s)\n' "$GIKI_EXPLORE_TOKEN" "$GIKI_EXPLORE_USER"
    printf 'register token %s\n' "$GIKI_EXPLORE_REGISTER_TOKEN"
    for name in server chrome; do
        if [ -f "$state/$name.pid" ] && kill -0 "$(cat "$state/$name.pid")" 2>/dev/null; then
            printf '%-14s running (pid %s)\n' "$name" "$(cat "$state/$name.pid")"
        else
            printf '%-14s NOT running\n' "$name"
        fi
    done
}

wait_for() {
    attempt=0
    while [ "$attempt" -lt 150 ]; do
        if curl --fail --silent --output /dev/null "$1"; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.2
    done
    echo "$2 did not come up at $1" >&2
    return 1
}

start_session() {
    if [ -f "$state/session.env" ]; then
        echo "a session is already running; tool/explore.sh stop first" >&2
        return 1
    fi
    mkdir -p "$state"

    if [ ! -f "$root/client/web/sqlite3.wasm" ]; then
        "$root/tool/fetch-sqlite-wasm.sh"
    fi
    # Rebuild unless the bundle on disk is provably this app, from these
    # sources. "index.html exists" is not enough: client/build/web is also
    # where `flutter build web --target=integration_test/...` leaves the test
    # bundle, and serving that looks exactly like a broken app -- a page that
    # renders, reports nonsense and answers no input.
    stamp="lib/main.dart $(find "$root/client/lib" "$root/client/pubspec.yaml" -type f -newer /dev/null -printf '%T@ %p\n' 2>/dev/null | sort | cksum)"
    if [ ! -f "$root/client/build/web/index.html" ] ||
        [ "$(cat "$state/bundle.stamp" 2>/dev/null || true)" != "$stamp" ] ||
        [ "${GIKI_EXPLORE_REBUILD:-}" = "1" ]; then
        echo "building the web bundle (a minute; skipped while the sources are unchanged)"
        (cd "$root/client" && flutter build web --release --target=lib/main.dart \
            >"$state/build.log" 2>&1) ||
            { echo "flutter build web failed; see $state/build.log" >&2; return 1; }
        printf '%s' "$stamp" >"$state/bundle.stamp"
    fi
    (cd "$root" && go build -o "$state/giki-server" ./cmd/giki-server)

    port=${GIKI_EXPLORE_PORT:-$(pick_port 8110)}
    cdp=${GIKI_EXPLORE_CDP:-$(pick_port 9222 "$port")}
    chrome=$(find_chrome)

    # localhost, not 127.0.0.1: WebAuthn needs a secure context, browsers grant
    # one to localhost, and the passkey domain has to equal the host in the URL.
    "$state/giki-server" \
        -db "$state/giki.sqlite" \
        -addr "127.0.0.1:$port" \
        -web-root "$root/client/build/web" \
        -tokens "$token:$user" \
        -passkey-domain localhost \
        -passkey-origin "http://localhost:$port" \
        -register-token "$register_token" \
        -log-level debug \
        >"$state/server.log" 2>&1 &
    echo $! >"$state/server.pid"
    wait_for "http://127.0.0.1:$port/healthz" "the giki server"

    # --no-sandbox because this often runs in a container without user
    # namespaces; it is a throwaway profile on a throwaway page either way.
    "$chrome" \
        --headless=new \
        --no-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu \
        --remote-debugging-port="$cdp" \
        --user-data-dir="$state/chrome" \
        --window-size=1280,900 \
        about:blank \
        >"$state/chrome.log" 2>&1 &
    echo $! >"$state/chrome.pid"
    wait_for "http://127.0.0.1:$cdp/json/version" "chrome"

    cat >"$state/session.env" <<ENV
GIKI_EXPLORE_URL=http://localhost:$port
GIKI_EXPLORE_PORT=$port
GIKI_EXPLORE_CDP_PORT=$cdp
GIKI_EXPLORE_DB=$state/giki.sqlite
GIKI_EXPLORE_SERVER_LOG=$state/server.log
GIKI_EXPLORE_TOKEN=$token
GIKI_EXPLORE_USER=$user
GIKI_EXPLORE_REGISTER_TOKEN=$register_token
ENV

    status_session
    echo
    echo "drive it with: tool/explore.mjs open /"
}

case "${1:-start}" in
start) start_session ;;
stop) stop_session ;;
status) status_session ;;
*)
    echo "usage: tool/explore.sh [start|stop|status]" >&2
    exit 2
    ;;
esac
