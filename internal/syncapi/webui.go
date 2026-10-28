package syncapi

import (
	"io"
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
		if info, err := os.Stat(filepath.Join(dir, clean)); err != nil || info.IsDir() {
			// The app has no URL routes: every screen lives at /. So any other
			// path is a typo or a stale link, and saying so beats quietly
			// showing the home screen under a URL that means nothing.
			notFound(w)
			return
		}

		setCacheHeaders(w)
		fileServer.ServeHTTP(w, r)
	})
}

// notFoundPage is deliberately plain: it must not load the app, whose service
// worker would otherwise take over a URL that does not exist.
const notFoundPage = `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Not found - giki</title>
<style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem}</style>
<h1>Not found</h1>
<p>There is nothing at this address.</p>
<p><a href="/">Open giki</a></p>
`

// notFound answers 404 with a page that leads back to the app.
func notFound(w http.ResponseWriter) {
	setCacheHeaders(w)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusNotFound)
	_, _ = io.WriteString(w, notFoundPage)
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
	setCacheHeaders(w)
	http.ServeContent(w, r, "index.html", info.ModTime(), file)
}

// setCacheHeaders makes the browser revalidate every file of the app.
//
// Flutter's file names carry no content hash: main.dart.js is main.dart.js in
// every release. A max-age on it kept running the previous build under a fresh
// index.html for up to an hour after a deploy -- for a local-first app, the
// old schema against the new server. Revalidating costs a 304, and offline
// the service worker (web/sw.js) answers instead.
func setCacheHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-cache")
}
