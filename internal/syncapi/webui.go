package syncapi

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// WebUI serves the built Flutter PWA from dir.
//
// Serving the app and the API from one origin is the point: it means the
// browser makes same-origin requests, so no CORS configuration is involved in
// a production deployment at all -- one fewer thing to get wrong, and one
// fewer header standing between a user and their own data.
func WebUI(dir string) http.Handler {
	fileServer := http.FileServer(http.Dir(dir))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clean := filepath.Clean(strings.TrimPrefix(r.URL.Path, "/"))
		// http.Dir already refuses to escape dir; this only decides whether to
		// serve a file or fall back to the shell.
		// index.html is served directly rather than through the file server,
		// which would redirect /index.html to ./ and cost a round trip.
		if clean == "." || clean == "/" || clean == "index.html" {
			serveShell(w, r, dir)
			return
		}
		if _, err := os.Stat(filepath.Join(dir, clean)); err != nil {
			// Unknown path: hand the request to the app rather than 404, so a
			// deep link or a reload inside the PWA still lands on the shell.
			serveShell(w, r, dir)
			return
		}

		// Everything except the shell and the service worker may be cached:
		// Flutter's build output is content-addressed enough that a stale
		// asset would be a stale asset of the version that asked for it.
		setCacheHeaders(w, clean)
		fileServer.ServeHTTP(w, r)
	})
}

// serveShell writes index.html.
//
// It opens the file itself rather than calling http.ServeFile, which has a
// special case that redirects any request path ending in /index.html to the
// directory -- an extra round trip on the app's own entry point.
func serveShell(w http.ResponseWriter, r *http.Request, dir string) {
	file, err := os.Open(filepath.Join(dir, "index.html"))
	if err != nil {
		// The web root is set but does not hold a build. Say so plainly:
		// the alternative is a 404 that looks like a routing problem.
		http.Error(w, "no index.html in the configured web root", http.StatusInternalServerError)
		return
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		http.Error(w, "cannot read index.html", http.StatusInternalServerError)
		return
	}
	setCacheHeaders(w, "index.html")
	http.ServeContent(w, r, "index.html", info.ModTime(), file)
}

// setCacheHeaders keeps the shell and the service worker uncacheable.
//
// If index.html or flutter_service_worker.js is cached, a user who already has
// the app installed keeps running the previous build after a deploy -- and with
// a local-first app that means the old schema against the new server.
func setCacheHeaders(w http.ResponseWriter, name string) {
	switch filepath.Base(name) {
	case "index.html", "flutter_service_worker.js", "version.json", "manifest.json":
		w.Header().Set("Cache-Control", "no-cache")
	default:
		w.Header().Set("Cache-Control", "public, max-age=3600")
	}
}
