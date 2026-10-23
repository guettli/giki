package syncapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("reached"))
	})
}

func TestCORSDisabledByDefault(t *testing.T) {
	handler := CORS(nil, okHandler())
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/sync", nil)
	req.Header.Set("Origin", "http://localhost:1234")
	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want none when no origin is configured", got)
	}
	if rec.Body.String() != "reached" {
		t.Error("request did not reach the handler")
	}
}

func TestCORSAllowsConfiguredOrigin(t *testing.T) {
	handler := CORS([]string{"http://localhost:8081", " http://localhost:8082 "}, okHandler())

	for _, origin := range []string{"http://localhost:8081", "http://localhost:8082"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/sync", nil)
		req.Header.Set("Origin", origin)
		handler.ServeHTTP(rec, req)

		if got := rec.Header().Get("Access-Control-Allow-Origin"); got != origin {
			t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, origin)
		}
		if got := rec.Header().Get("Vary"); got != "Origin" {
			t.Errorf("Vary = %q, want Origin", got)
		}
		if rec.Body.String() != "reached" {
			t.Error("allowed request did not reach the handler")
		}
	}
}

func TestCORSRejectsOtherOrigins(t *testing.T) {
	handler := CORS([]string{"http://localhost:8081"}, okHandler())

	for _, origin := range []string{
		"http://evil.example",
		"http://localhost:8081.evil.example", // no suffix matching
		"http://localhost",                   // no prefix matching
		"HTTP://LOCALHOST:8081",              // origins are compared exactly
	} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/sync", nil)
		req.Header.Set("Origin", origin)
		handler.ServeHTTP(rec, req)

		if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
			t.Errorf("origin %q was allowed (%q)", origin, got)
		}
		// The request still reaches the handler: it is the browser that
		// refuses to hand the response to the page.
		if rec.Body.String() != "reached" {
			t.Error("request did not reach the handler")
		}
	}
}

func TestCORSAnswersPreflight(t *testing.T) {
	handler := CORS([]string{"http://localhost:8081"}, http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			t.Error("preflight reached the handlers, which would reject it as unauthenticated")
		}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodOptions, "/api/v1/sync", nil)
	req.Header.Set("Origin", "http://localhost:8081")
	req.Header.Set("Access-Control-Request-Method", "POST")
	req.Header.Set("Access-Control-Request-Headers", "authorization, content-type")
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Errorf("preflight status = %d, want 204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Headers"); got != "Authorization, Content-Type" {
		t.Errorf("Access-Control-Allow-Headers = %q, want the bearer token and the JSON body to be allowed", got)
	}
	if got := rec.Header().Get("Access-Control-Allow-Methods"); got == "" {
		t.Error("preflight did not say which methods are allowed")
	}
}

func TestCORSPreflightFromDisallowedOrigin(t *testing.T) {
	handler := CORS([]string{"http://localhost:8081"}, okHandler())

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodOptions, "/api/v1/sync", nil)
	req.Header.Set("Origin", "http://evil.example")
	req.Header.Set("Access-Control-Request-Method", "POST")
	handler.ServeHTTP(rec, req)

	// Answered, but without the header that would let the page proceed.
	if rec.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want none", got)
	}
	if rec.Body.String() == "reached" {
		t.Error("an unauthenticated preflight reached the handlers")
	}
}

func TestCORSPlainOptionsReachesTheMux(t *testing.T) {
	// An OPTIONS request without Access-Control-Request-Method is not a
	// preflight. Swallowing it would hide the mux's 404s and 405s.
	handler := CORS([]string{"http://localhost:8081"}, okHandler())

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodOptions, "/does-not-exist", nil)
	req.Header.Set("Origin", "http://localhost:8081")
	handler.ServeHTTP(rec, req)

	if rec.Body.String() != "reached" {
		t.Errorf("plain OPTIONS was answered by the middleware (status %d)", rec.Code)
	}
}

func TestCORSWithoutOriginHeader(t *testing.T) {
	// curl, a health checker or a server-to-server call sends no Origin.
	handler := CORS([]string{"http://localhost:8081"}, okHandler())

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	handler.ServeHTTP(rec, req)

	if rec.Body.String() != "reached" {
		t.Error("a request without Origin did not reach the handler")
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("Access-Control-Allow-Origin = %q, want none without an Origin", got)
	}
	if got := rec.Header().Get("Vary"); got != "Origin" {
		t.Errorf("Vary = %q, want Origin even without an Origin header", got)
	}
}
