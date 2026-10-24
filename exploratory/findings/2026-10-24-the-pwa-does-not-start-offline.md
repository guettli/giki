# The PWA does not start offline

- **Found**: 2026-10-24 · **Charter**: 06-attachments.md (while testing "attach while the server is down, then reload") · **Status**: fixed (`client/web/sw.js`, `tool/offline-check.sh` in CI)

## What happens

With the server down, reloading giki shows Chrome's "This site can't be
reached". The app is "offline by default" only as long as the tab stays open.

Three causes:

1. Flutter 3.47's `flutter_service_worker.js` is a stub that unregisters
   itself, so nothing kept a copy of the app.
2. The engine (CanvasKit) and the Roboto font came from `www.gstatic.com` and
   `fonts.gstatic.com`, so even a cached shell could not have rendered.
3. Separately, the server sent `max-age=3600` for `main.dart.js` and
   `flutter_bootstrap.js`, which carry no content hash: after a deploy, a
   browser could run the previous build under the new `index.html` for an
   hour.

A deep link (`/some/path`) did not start the app at all, online or not: Dart
resolved `sqlite3.wasm` against the page address instead of `<base href>`,
fetched `/some/sqlite3.wasm`, got the HTML shell, and failed to compile it.

## Reproduce

From a fresh `tool/explore.sh start`:

```sh
tool/explore.mjs open /
kill "$(cat .explore/server.pid)"
tool/explore.mjs open /          # "no semantics": the browser error page
tool/explore.mjs eval "performance.getEntriesByType('resource').map(r => r.name).join(' ')"
```

Observed: the error page offline; online, two `gstatic.com` URLs in the list.
Expected: the home screen, from the last version that loaded.

## Why it matters

A wiki on the phone that cannot be opened on a plane, in a tunnel, or while
the server is being redeployed. Every user is hit, and no test noticed,
because every test ran against a live server.

## Evidence

`tool/offline-check.sh` loads the app, stops the server, and reloads on `/`
and on a deep link. Without the worker registration it fails with "the
service worker never cached the app"; with it: "ok: the app starts offline,
on / and on a deep link".
