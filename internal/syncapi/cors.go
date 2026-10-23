package syncapi

import (
	"net/http"
	"slices"
	"strings"
)

// CORS wraps next so that a PWA served from another origin can reach the API.
//
// This is not an optional nicety for giki: during development the Flutter app
// is served by `flutter run` on one port while the server listens on another,
// and the end-to-end test does the same. In production both are usually behind
// one origin and no origin needs to be allowed at all, which is why the empty
// list means "send no CORS headers".
//
// Only exact origins are accepted -- no wildcard, no prefix matching. A
// wildcard would be a poor fit here anyway: the API is authenticated with a
// bearer token the client stores itself, so the useful question is not "may
// this page read the response" but "which deployment is this", and that is
// always a known list.
func CORS(allowedOrigins []string, next http.Handler) http.Handler {
	allowed := make([]string, 0, len(allowedOrigins))
	for _, origin := range allowedOrigins {
		if trimmed := strings.TrimSpace(origin); trimmed != "" {
			allowed = append(allowed, trimmed)
		}
	}
	if len(allowed) == 0 {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		// Vary unconditionally: the response differs by Origin even when this
		// particular origin is not allowed, and a cache that misses that would
		// serve one site's answer to another.
		w.Header().Add("Vary", "Origin")

		// A preflight is identified by its Access-Control-Request-Method
		// header, not merely by being an OPTIONS request. Answering every
		// OPTIONS here would hide the mux's own 404s and 405s, and would tell
		// a browser that paths which do not exist accept cross-origin calls.
		isPreflight := r.Method == http.MethodOptions &&
			r.Header.Get("Access-Control-Request-Method") != ""
		originAllowed := origin != "" && slices.Contains(allowed, origin)

		if originAllowed {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			if isPreflight {
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
				w.Header().Set("Access-Control-Max-Age", "600")
			}
		}

		// A preflight carries no credentials, so it must be answered here: the
		// handlers would reject it as unauthenticated. A preflight from an
		// origin that is not allowed gets the same 204 without the
		// Access-Control-Allow-Origin header, which is what makes the browser
		// refuse to send the real request.
		if isPreflight {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
