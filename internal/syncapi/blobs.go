package syncapi

import (
	"errors"
	"io"
	"net/http"

	"github.com/guettli/giki/internal/store"
)

// MaxBlobBytes caps one attachment. The client enforces the same limit before
// a file ever reaches the outbox, so an oversized upload here means a client
// bug or a client that is not giki.
const MaxBlobBytes = 10 << 20 // 10 MiB

// handlePutBlob stores attachment bytes under their SHA-256:
//
//	PUT /api/v1/blobs/{sha256}   body: the raw bytes
//
// Idempotent, so a client that lost the answer simply uploads again.
func (s *Server) handlePutBlob(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	key := r.PathValue("sha256")
	if !store.ValidBlobKey(key) {
		s.fail(w, r, http.StatusBadRequest, "the path must end in a lowercase hex sha256", nil)
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBlobBytes))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		s.fail(w, r, http.StatusRequestEntityTooLarge, "attachments are limited to 10 MiB", nil)
		return
	}
	if err != nil {
		s.fail(w, r, http.StatusBadRequest, "could not read the upload", err)
		return
	}
	err = s.store.PutBlob(r.Context(), key, data, identity.UserID)
	if errors.Is(err, store.ErrBlobMismatch) {
		s.fail(w, r, http.StatusBadRequest, err.Error(), nil)
		return
	}
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not store the upload", err)
		return
	}
	s.log.InfoContext(r.Context(), "blob stored",
		"user_id", identity.UserID, "sha256", key, "size", len(data))
	writeJSON(w, http.StatusOK, map[string]any{"sha256": key, "size": len(data)})
}

// handleGetBlob serves attachment bytes.
//
// Always as an opaque download: the server never learns or trusts a type for
// the bytes (that lives in the synced attachment row), and serving
// user-uploaded HTML or SVG from the app's own origin would be stored XSS.
// The client turns the bytes into an image or a file itself.
func (s *Server) handleGetBlob(w http.ResponseWriter, r *http.Request) {
	if _, err := s.auth.Authenticate(r); err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	key := r.PathValue("sha256")
	if !store.ValidBlobKey(key) {
		s.fail(w, r, http.StatusBadRequest, "the path must end in a lowercase hex sha256", nil)
		return
	}
	data, err := s.store.Blob(r.Context(), key)
	if errors.Is(err, store.ErrBlobNotFound) {
		s.fail(w, r, http.StatusNotFound, "no such blob", nil)
		return
	}
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not read the blob", err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Content-Disposition", "attachment")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	// Content-addressed, so the bytes behind this URL can never change.
	h.Set("Cache-Control", "private, max-age=31536000, immutable")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
