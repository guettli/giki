#!/bin/sh
# Checks that the PWA starts without a network: load it once, stop the
# server, reload, and expect the home screen -- on / and on a deep link.
#
#   tool/offline-check.sh
#
# Runs on the exploratory harness (tool/explore.sh), so it needs the same
# things: Go, Flutter, Chrome (or CHROME_EXECUTABLE) and Node 22+. It ends the
# exploratory session it starts, database included.
#
# Flutter's own service worker became a stub that unregisters itself, and for
# a while giki had no offline start at all without anyone noticing: every
# test ran against a live server.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state="$root/.explore"

x() { node "$root/tool/explore.mjs" "$@"; }

# until_true SECONDS JS: polls a JavaScript expression in the page.
until_true() {
    seconds=$1
    expression=$2
    while [ "$seconds" -gt 0 ]; do
        if [ "$(x eval "$expression" 2>/dev/null || true)" = "true" ]; then
            return 0
        fi
        seconds=$((seconds - 1))
        sleep 1
    done
    return 1
}

# home_screen SECONDS: waits for the app's own UI, not just a page.
home_screen() {
    seconds=$1
    while [ "$seconds" -gt 0 ]; do
        if x text 2>/dev/null | grep -q "New page"; then
            return 0
        fi
        seconds=$((seconds - 1))
        sleep 1
    done
    return 1
}

trap '"$root/tool/explore.sh" stop >/dev/null 2>&1 || true' EXIT
"$root/tool/explore.sh" stop >/dev/null 2>&1 || true
"$root/tool/explore.sh" start

x open / >/dev/null
home_screen 60 || { echo "the app did not start even online" >&2; exit 1; }

# The worker caches what the page loaded once it is in control; wait until
# the shell, the app, the engine and the database engine are all there.
until_true 60 "(async () => {
  if (!navigator.serviceWorker.controller) return false;
  const keys = (await (await caches.open('giki-app-v1')).keys()).map((r) => new URL(r.url).pathname);
  return ['/', '/main.dart.js', '/sqlite3.wasm'].every((p) => keys.includes(p)) &&
    keys.some((p) => p.endsWith('/canvaskit.wasm'));
})()" || {
    echo "the service worker never cached the app" >&2
    x eval "(async () => (await (await caches.open('giki-app-v1')).keys()).map((r) => r.url).join(' '))()" >&2 || true
    exit 1
}

. "$state/session.env"
kill "$(cat "$state/server.pid")"
gone=10
while curl --silent --max-time 2 --output /dev/null "$GIKI_EXPLORE_URL/healthz"; do
    gone=$((gone - 1))
    if [ "$gone" -eq 0 ]; then
        echo "the server is still answering; the check would prove nothing" >&2
        exit 1
    fi
    sleep 1
done

for path in / /some/deep/link; do
    x open "$path" >/dev/null || true
    if ! home_screen 30; then
        echo "offline, $path did not start the app" >&2
        x console >&2 || true
        exit 1
    fi
done

echo "ok: the app starts offline, on / and on a deep link"
