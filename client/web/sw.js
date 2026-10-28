// giki's service worker: it lets the app start without a network.
//
// Network first, cache second. Online, every load gets the current release,
// so a deploy never leaves anyone on the previous build; offline, the app
// starts from the last files that loaded. The API is never cached: sync has
// its own outbox, and the local database is the source of truth.
//
// Flutter's own flutter_service_worker.js is deprecated and only unregisters
// itself; web/flutter_bootstrap.js no longer asks for it.
//
// Known limit: each file is replaced on its own. A load cut off right after a
// deploy can leave files of two releases in the cache, which matters only if
// the next start is offline. A cache per build would close that.
'use strict';

const CACHE = 'giki-app-v1';

// Same origin only: built with --no-web-resources-cdn, the app loads its
// engine and fonts from its own server.
function cacheable(url) {
  const u = new URL(url);
  return (
    u.origin === self.location.origin &&
    !u.pathname.startsWith('/api/') &&
    u.pathname !== '/healthz'
  );
}

// One copy of the shell, whatever URL it was loaded from: the server answers
// every page address with index.html.
const SHELL = new URL('./', self.location).href;

// How long the network gets before a cached copy answers instead. Only the
// headers have to arrive in time; a slow body is fine. Without it, a hanging
// connection (captive Wi-Fi, one bar of signal) showed a blank page for as
// long as the browser's own timeout.
const NETWORK_TIMEOUT_MS = 4000;

// After one timeout, the cache answers at once for a while: the app loads its
// files one after another, and a timeout each added up to half a minute.
const SLOW_NETWORK_MS = 30000;
let slowUntil = 0;

// Only a complete, genuine copy of the file: a 206 cannot be stored, and an
// HTML page stored as main.dart.js -- the server's shell for an unknown path,
// a captive portal's login page -- would break the next offline start.
async function keep(key, response, navigate) {
  const html = (response.headers.get('Content-Type') || '').startsWith('text/html');
  if (response.status !== 200 || response.redirected || html !== navigate) {
    return;
  }
  try {
    await (await caches.open(CACHE)).put(key, response);
  } catch (_) {
    // Storage full or evicted: the app still works online.
  }
}

async function respond(event) {
  const request = event.request;
  const navigate = request.mode === 'navigate';
  const key = navigate ? SHELL : request;

  // Stored on the side, so the page gets the response as it streams in. The
  // event lives until the network has answered, even when the cache answered
  // the page first, so the copy is refreshed either way.
  const network = fetch(request).then((response) => {
    event.waitUntil(keep(key, response.clone(), navigate));
    return response;
  });
  event.waitUntil(network.catch(() => {}));

  const cache = await caches.open(CACHE);
  if (Date.now() < slowUntil) {
    const hit = await cache.match(key);
    if (hit) {
      return hit;
    }
  }
  let timer;
  const fresh = await Promise.race([
    // A 404 for a page is the server's real answer (an address that does not
    // exist), not an outage: show it rather than the cached app.
    network.then(
      (response) => (response.ok || (navigate && response.status < 500) ? response : null),
      () => null,
    ),
    new Promise((resolve) => {
      timer = setTimeout(() => {
        slowUntil = Date.now() + SLOW_NETWORK_MS;
        resolve(null);
      }, NETWORK_TIMEOUT_MS);
    }),
  ]);
  clearTimeout(timer);
  if (fresh) {
    return fresh;
  }
  // Offline, slow, or an error from a proxy whose backend is down.
  const hit = await cache.match(key);
  return hit || network;
}

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) {
        if (key !== CACHE) {
          await caches.delete(key);
        }
      }
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method === 'GET' && cacheable(event.request.url)) {
    event.respondWith(respond(event));
  }
});

// The page lists what it loaded before this worker took control; those
// requests never passed through the fetch handler above. See index.html.
self.addEventListener('message', (event) => {
  if (event.data?.type !== 'cache' || !Array.isArray(event.data.urls)) {
    return;
  }
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      for (const url of event.data.urls) {
        if (typeof url !== 'string' || !cacheable(url) || (await cache.match(url))) {
          continue;
        }
        const shell = url === SHELL;
        try {
          await keep(url, await fetch(url), shell);
        } catch (_) {
          // Offline already; the next online start fills the gap.
        }
      }
    })(),
  );
});
