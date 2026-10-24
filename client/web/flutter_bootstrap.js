{{flutter_js}}
{{flutter_build_config}}

// No serviceWorkerSettings: Flutter's service worker is deprecated and only
// unregisters itself. giki registers its own, sw.js; see index.html.
_flutter.loader.load();
