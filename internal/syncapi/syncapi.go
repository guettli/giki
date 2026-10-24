// Package syncapi is giki's HTTP surface: JSON over REST, one endpoint that
// matters.
//
// Why JSON and not gRPC: browsers do not expose HTTP/2 trailers, so gRPC from
// a Flutter Web PWA needs grpc-web plus a proxy in front of the server -- and
// giki's payloads are generic JSON objects built by SQLite triggers, which
// Protobuf would only be able to carry as an opaque string or a
// google.protobuf.Struct. That trades away the one thing strong typing was
// supposed to buy, and costs the ability to read a sync batch in the browser's
// Network tab. See docs/sync-protocol.md.
package syncapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/guettli/giki/internal/auth"
	"github.com/guettli/giki/internal/passkey"
	"github.com/guettli/giki/internal/store"
)

// Limits on one request. A PWA that has been offline for a month must not be
// able to turn its catch-up into an out-of-memory condition on the server.
const (
	maxBodyBytes     = 8 << 20 // 8 MiB
	maxMutations     = 1000
	defaultMaxDeltas = 500
)

// SyncRequest is one push-and-pull round trip, the only call the background
// worker makes.
type SyncRequest struct {
	// DeviceID identifies the pushing device; deltas are not echoed back to it.
	DeviceID string `json:"device_id"`
	// Cursor is the client's last_sync_cursor: the highest ChangeLog seq it
	// has already written locally. 0 means "I am empty, send me everything".
	Cursor int64 `json:"cursor"`
	// Mutations is the drained sync_outbox, in local commit order.
	Mutations []store.Mutation `json:"mutations"`
	// MaxDeltas caps the delta count in the response. Optional.
	MaxDeltas int `json:"max_deltas,omitempty"`
}

// SyncResponse reports the fate of every pushed mutation and carries the
// deltas the client is missing.
type SyncResponse struct {
	// Cursor is the new last_sync_cursor the client must persist -- but only
	// after it has committed every Change below.
	Cursor int64 `json:"cursor"`
	// Results has one entry per pushed mutation, matched by client_seq.
	Results []store.Result `json:"results"`
	// Changes are the deltas, oldest first; apply them in order.
	Changes []store.Change `json:"changes"`
	// HasMore means more deltas are waiting: sync again immediately.
	HasMore bool `json:"has_more"`
	// ServerTime lets a client notice that its own clock is off, which with
	// Last-Write-Wins is worth knowing about.
	ServerTime string `json:"server_time"`
}

// Server serves the sync API, and optionally the PWA itself.
type Server struct {
	store         *store.Store
	auth          auth.Authenticator
	log           *slog.Logger
	webRoot       string
	passkeys      *passkey.Service
	registerToken string
}

// Option configures a Server.
type Option func(*Server)

// WithWebRoot serves the built Flutter app from dir, on the same origin as the
// API. Without it the server answers only the API paths.
func WithWebRoot(dir string) Option {
	return func(s *Server) { s.webRoot = dir }
}

// WithPasskeys enables the WebAuthn endpoints.
//
// registerToken, if set, is what someone must present to create a *new*
// account; an existing signed-in user needs no token to add another
// authenticator. Empty means new accounts are closed, which is the right
// default for an instance with authentication but no authorization.
func WithPasskeys(service *passkey.Service, registerToken string) Option {
	return func(s *Server) {
		s.passkeys = service
		s.registerToken = registerToken
	}
}

// New builds a Server. log may be nil.
func New(st *store.Store, a auth.Authenticator, log *slog.Logger, opts ...Option) *Server {
	if log == nil {
		log = slog.Default()
	}
	s := &Server{store: st, auth: a, log: log}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Routes returns the full HTTP surface.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /api/v1/sync", s.handleSync)
	mux.HandleFunc("GET /api/v1/history", s.handleHistory)
	mux.HandleFunc("PUT /api/v1/blobs/{sha256}", s.handlePutBlob)
	mux.HandleFunc("GET /api/v1/blobs/{sha256}", s.handleGetBlob)

	mux.HandleFunc("POST /api/v1/auth/passkey/register/begin", s.handleRegisterBegin)
	mux.HandleFunc("POST /api/v1/auth/passkey/register/finish", s.handleRegisterFinish)
	mux.HandleFunc("POST /api/v1/auth/passkey/login/begin", s.handleLoginBegin)
	mux.HandleFunc("POST /api/v1/auth/passkey/login/finish", s.handleLoginFinish)
	mux.HandleFunc("GET /api/v1/auth/whoami", s.handleWhoami)
	mux.HandleFunc("POST /api/v1/auth/logout", s.handleLogout)
	mux.HandleFunc("GET /api/v1/auth/passkeys", s.handleListPasskeys)
	mux.HandleFunc("DELETE /api/v1/auth/passkeys/{id}", s.handleDeletePasskey)
	if s.webRoot != "" {
		mux.Handle("GET /", WebUI(s.webRoot))
		// Without this, a GET to an API path falls through to the app shell:
		// ServeMux prefers the catch-all "GET /" over a pattern that matches
		// the path but not the method, so "POST /api/v1/sync" does not produce
		// its 405 any more. A client would then receive 200 and a page of HTML
		// where it expects JSON -- the kind of answer that gets reported as
		// "sync silently does nothing".
		mux.HandleFunc("GET /api/", func(w http.ResponseWriter, r *http.Request) {
			s.fail(w, r, http.StatusMethodNotAllowed, "method not allowed", nil)
		})
	}
	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	cursor, err := s.store.Cursor(r.Context())
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "database unavailable", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "ok",
		"cursor":      cursor,
		"server_time": store.Now(),
	})
}

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}

	var req SyncRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		s.fail(w, r, http.StatusBadRequest, "malformed request body", err)
		return
	}
	if req.DeviceID == "" {
		s.fail(w, r, http.StatusBadRequest, "device_id is required", nil)
		return
	}
	if req.Cursor < 0 {
		s.fail(w, r, http.StatusBadRequest, "cursor must not be negative", nil)
		return
	}
	if len(req.Mutations) > maxMutations {
		s.fail(w, r, http.StatusRequestEntityTooLarge,
			fmt.Sprintf("at most %d mutations per request", maxMutations), nil)
		return
	}

	actor := store.Actor{UserID: identity.UserID, DeviceID: req.DeviceID}
	results, err := s.store.ApplyBatch(r.Context(), actor, req.Mutations)
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not apply batch", err)
		return
	}

	limit := req.MaxDeltas
	if limit <= 0 || limit > defaultMaxDeltas {
		limit = defaultMaxDeltas
	}
	// Read the head BEFORE the deltas. If another device commits in between,
	// that change lands above this head and is simply picked up next round --
	// reading the head afterwards could skip it.
	head, err := s.store.Cursor(r.Context())
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not read cursor", err)
		return
	}
	changes, hasMore, err := s.store.Changes(r.Context(), req.Cursor, req.DeviceID, limit)
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not read deltas", err)
		return
	}

	// The cursor the client may store is the last delta it actually received.
	// With no deltas left it may jump to the head read above: the entries in
	// between are this device's own pushes, which are never echoed back, so
	// without the jump the device would re-request them on every sync forever.
	cursor := req.Cursor
	switch {
	case len(changes) > 0:
		cursor = changes[len(changes)-1].Seq
	case !hasMore && head > cursor:
		cursor = head
	}

	if err := s.store.TouchDevice(r.Context(), req.DeviceID, identity.UserID, cursor); err != nil {
		// Device bookkeeping is diagnostics, not correctness: log it and
		// still answer, because the client's data is already committed.
		s.log.WarnContext(r.Context(), "could not record device sync",
			"device_id", req.DeviceID, "error", err)
	}

	rejected := 0
	for _, res := range results {
		if res.Status == store.StatusRejected {
			rejected++
			s.log.WarnContext(r.Context(), "mutation rejected",
				"user_id", identity.UserID, "device_id", req.DeviceID,
				"client_seq", res.ClientSeq, "reason", res.Reason)
		}
	}
	s.log.InfoContext(r.Context(), "sync",
		"user_id", identity.UserID, "device_id", req.DeviceID,
		"pushed", len(req.Mutations), "rejected", rejected,
		"deltas", len(changes), "cursor", cursor)

	writeJSON(w, http.StatusOK, SyncResponse{
		Cursor:     cursor,
		Results:    results,
		Changes:    changes,
		HasMore:    hasMore,
		ServerTime: store.Now(),
	})
}

// handleHistory serves the audit trail of one record: who changed what, when.
func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	table := r.URL.Query().Get("table")
	recordID := r.URL.Query().Get("record_id")
	if table == "" || recordID == "" {
		s.fail(w, r, http.StatusBadRequest, "table and record_id are required", nil)
		return
	}
	limit := 0
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 0 {
			s.fail(w, r, http.StatusBadRequest, "limit must be a non-negative integer", nil)
			return
		}
	}

	history, err := s.store.RecordHistory(r.Context(), table, recordID, limit)
	if errors.Is(err, store.ErrRejected) {
		s.fail(w, r, http.StatusBadRequest, err.Error(), nil)
		return
	}
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not read history", err)
		return
	}
	s.log.InfoContext(r.Context(), "history read",
		"user_id", identity.UserID, "table", table, "record_id", recordID)
	writeJSON(w, http.StatusOK, map[string]any{
		"table":     table,
		"record_id": recordID,
		"history":   history,
	})
}

// fail answers with a JSON error. The message is for the client; err is only
// logged, so internal details never leak into a response body.
func (s *Server) fail(w http.ResponseWriter, r *http.Request, code int, message string, err error) {
	if err != nil {
		s.log.WarnContext(r.Context(), "request failed",
			"path", r.URL.Path, "status", code, "message", message, "error", err)
	}
	writeJSON(w, code, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		// The status line is already out; all that is left is a log line.
		slog.Error("could not write response body", "error", err)
	}
}
