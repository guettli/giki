// giki's service worker: it lets the app start without a network.
//
// Network first, cache second. Online, every load gets the current release,
// so a deploy never leaves anyone on the previous build; offline, the app
// starts from the last files that loaded. The API is never cached: sync has
// its own outbox, and the local database is the source of truth.
//
// Flutter's own flutter_service_worker.js is deprecated and only unregisters
// itself; web/flutter_bootstrap.js no longer asks for it.
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

// Only complete answers: a 206 cannot be stored, and an error page stored as
// main.dart.js would break the next offline start.
async function store(cache, key, response) {
  if (response.status === 200) {
    await cache.put(key, response.clone());
  }
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
  const request = event.request;
  if (request.method !== 'GET' || !cacheable(request.url)) {
    return;
  }
  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      try {
        const response = await fetch(request);
        await store(cache, request, response);
        return response;
      } catch (error) {
        const hit = await cache.match(request);
        if (hit) {
          return hit;
        }
        // A deep link or a reload inside the app: the server would have
        // answered with the shell, so the cached shell is the right answer.
        if (request.mode === 'navigate') {
          const shell = await cache.match(new URL('./', self.location).href);
          if (shell) {
            return shell;
          }
        }
        throw error;
      }
    })(),
  );
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
        try {
          await store(cache, url, await fetch(url));
        } catch (_) {
          // Offline already; the next online start fills the gap.
        }
      }
    })(),
  );
});
