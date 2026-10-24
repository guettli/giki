package syncapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/guettli/giki/internal/auth"
	"github.com/guettli/giki/internal/store"
)

// webDir builds a directory shaped like a Flutter web build.
func webDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"index.html":                "<!doctype html><title>giki</title>",
		"main.dart.js":              "// app",
		"flutter_service_worker.js": "// service worker",
		"sqlite3.wasm":              "wasm",
		"assets/db/schema.sql":      "-- schema",
	}
	for name, body := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return dir
}

func TestWebUIServesTheApp(t *testing.T) {
	handler := WebUI(webDir(t))

	for path, want := range map[string]string{
		"/":                     "<!doctype html><title>giki</title>",
		"/index.html":           "<!doctype html><title>giki</title>",
		"/main.dart.js":         "// app",
		"/sqlite3.wasm":         "wasm",
		"/assets/db/schema.sql": "-- schema",
		"/some/deep/link":       "<!doctype html><title>giki</title>", // falls back to the shell
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, rec.Code)
			continue
		}
		if got := rec.Body.String(); got != want {
			t.Errorf("GET %s served %q, want %q", path, got, want)
		}
	}
}

func TestWebUICacheHeaders(t *testing.T) {
	handler := WebUI(webDir(t))

	// None of these names carries a content hash. A cached main.dart.js under
	// a fresh index.html ran the previous build for up to an hour after a
	// deploy; for a local-first app that means the old schema. no-cache still
	// lets the browser keep the bytes: it revalidates, and gets a 304.
	for _, path := range []string{"/", "/index.html", "/main.dart.js", "/sqlite3.wasm", "/assets/db/schema.sql"} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
			t.Errorf("GET %s Cache-Control = %q, want no-cache", path, got)
		}
	}
}

func TestWebUIDoesNotEscapeItsDirectory(t *testing.T) {
	dir := webDir(t)
	secret := filepath.Join(filepath.Dir(dir), "secret.txt")
	if err := os.WriteFile(secret, []byte("do not serve me"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	handler := WebUI(dir)

	for _, path := range []string{
		"/../secret.txt",
		"/..%2fsecret.txt",
		"/assets/../../secret.txt",
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if body := rec.Body.String(); body == "do not serve me" {
			t.Errorf("GET %s escaped the web root", path)
		}
	}
}

// TestRoutesPreferTheAPI guards the one way this could break the sync
// protocol: a catch-all that shadows an API path.
func TestRoutesPreferTheAPI(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	defer st.Close()
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := New(st, auth.OpenDev{UserID: "alice"}, quiet, WithWebRoot(webDir(t))).Routes()

	// /healthz is the API's, not a 404-turned-shell.
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Errorf("GET /healthz = %d %q, want the JSON health endpoint",
			rec.Code, rec.Header().Get("Content-Type"))
	}

	// A GET to the sync endpoint must not be answered with the app shell:
	// that would turn a protocol mistake into a 200 and an HTML body, which a
	// client would try to parse as JSON.
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/sync", nil))
	if rec.Code == http.StatusOK {
		t.Errorf("GET /api/v1/sync = 200 %q, want a method error", rec.Body.String())
	}

	// And the app is still served.
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK || rec.Body.String() == "" {
		t.Errorf("GET / = %d, want the app shell", rec.Code)
	}
}
