package syncapi

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/guettli/giki/internal/auth"
	"github.com/guettli/giki/internal/passkey"
	"github.com/guettli/giki/internal/store"
)

// Registration is gated because giki has authentication but no
// authorization: every signed-in user can read and write the whole knowledge
// base. On a public URL, open registration would therefore be the same thing
// as no authentication at all.
//
// So a *new* account needs the registration token. An existing user adding a
// second authenticator -- their phone, a hardware key -- only needs to be
// signed in already.

// beginRegistrationRequest starts registering an authenticator.
type beginRegistrationRequest struct {
	// UserID is the account to register. Required with the registration
	// token; ignored (and taken from the session) when already signed in.
	UserID string `json:"user_id"`
	// DisplayName is shown by the authenticator and in the app.
	DisplayName string `json:"display_name"`
}

// ceremonyResponse hands the browser the options to pass to the WebAuthn API.
type ceremonyResponse struct {
	CeremonyID string          `json:"ceremony_id"`
	Options    json.RawMessage `json:"options"`
}

// finishCeremonyRequest carries the authenticator's answer.
type finishCeremonyRequest struct {
	CeremonyID string `json:"ceremony_id"`
	// Credential is the PublicKeyCredential as JSON, passed through to the
	// WebAuthn library untouched.
	Credential json.RawMessage `json:"credential"`
	// Label names the authenticator in the list of registered passkeys.
	Label string `json:"label"`
}

func (s *Server) passkeysEnabled(w http.ResponseWriter, r *http.Request) bool {
	if s.passkeys == nil {
		s.fail(w, r, http.StatusNotImplemented,
			"passkeys are not configured on this server (see -passkey-domain)", nil)
		return false
	}
	return true
}

// authorizeRegistration decides who, if anyone, may register an authenticator.
//
// Two ways in: the registration token (a new account) or an existing session
// (another key for the account that is already signed in).
func (s *Server) authorizeRegistration(r *http.Request, requested string) (userID string, newAccount bool, err error) {
	if identity, authErr := s.auth.Authenticate(r); authErr == nil {
		// Signed in: may only add keys to their own account. Anything else
		// would let one user register an authenticator against another's
		// account.
		if requested != "" && requested != identity.UserID {
			return "", false, fmt.Errorf("%w: a session may only register passkeys for %s",
				errForbidden, identity.UserID)
		}
		return identity.UserID, false, nil
	}

	if s.registerToken == "" {
		return "", false, fmt.Errorf("%w: new accounts are closed on this server (see -register-token)",
			errForbidden)
	}
	presented, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return "", false, fmt.Errorf("%w: registration requires a bearer token", auth.ErrUnauthorized)
	}
	presented = strings.TrimSpace(presented)
	if subtle.ConstantTimeCompare([]byte(presented), []byte(s.registerToken)) != 1 {
		return "", false, fmt.Errorf("%w: registration requires a valid token", auth.ErrUnauthorized)
	}
	if requested == "" {
		return "", false, fmt.Errorf("%w: user_id is required when registering a new account", errBadRequest)
	}
	return requested, true, nil
}

// errForbidden and errBadRequest let authorizeRegistration report which status
// its refusal deserves without knowing about HTTP.
var (
	errForbidden  = errors.New("forbidden")
	errBadRequest = errors.New("bad request")
)

func (s *Server) handleRegisterBegin(w http.ResponseWriter, r *http.Request) {
	if !s.passkeysEnabled(w, r) {
		return
	}
	var req beginRegistrationRequest
	if !decodeJSON(s, w, r, &req) {
		return
	}

	userID, newAccount, err := s.authorizeRegistration(r, req.UserID)
	switch {
	case errors.Is(err, errForbidden):
		s.fail(w, r, http.StatusForbidden, err.Error(), nil)
		return
	case errors.Is(err, errBadRequest):
		s.fail(w, r, http.StatusBadRequest, err.Error(), nil)
		return
	case errors.Is(err, auth.ErrUnauthorized):
		s.fail(w, r, http.StatusUnauthorized, "registration requires a valid token", err)
		return
	case err != nil:
		s.fail(w, r, http.StatusInternalServerError, "could not authorize registration", err)
		return
	}

	if newAccount {
		// The registration token creates accounts; it does not join existing
		// ones. Without this check anyone ever handed the token could attach
		// their own authenticator to somebody else's account and then write as
		// them -- which would also make the audit trail forgeable, the one
		// property giki still claims while it has no authorization.
		//
		// Refused before BeginRegistration, because the ceremony options
		// contain the account's WebAuthn handle and the ids of every
		// authenticator it has registered.
		exists, err := s.store.UserHasPasskey(r.Context(), userID)
		if err != nil {
			s.fail(w, r, http.StatusInternalServerError, "could not check the account", err)
			return
		}
		if exists {
			s.log.WarnContext(r.Context(), "registration token used for an existing account",
				"user_id", userID)
			s.fail(w, r, http.StatusConflict,
				"that account already exists; sign in with one of its passkeys and add another from there", nil)
			return
		}
	}

	ceremonyID, options, err := s.passkeys.BeginRegistration(r.Context(), userID, req.DisplayName)
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not begin registration", err)
		return
	}
	s.log.InfoContext(r.Context(), "passkey registration begun",
		"user_id", userID, "new_account", newAccount)
	writeJSON(w, http.StatusOK, ceremonyResponse{CeremonyID: ceremonyID, Options: options})
}

func (s *Server) handleRegisterFinish(w http.ResponseWriter, r *http.Request) {
	if !s.passkeysEnabled(w, r) {
		return
	}
	var req finishCeremonyRequest
	if !decodeJSON(s, w, r, &req) {
		return
	}
	if req.CeremonyID == "" || len(req.Credential) == 0 {
		s.fail(w, r, http.StatusBadRequest, "ceremony_id and credential are required", nil)
		return
	}

	// No authorization check here: the ceremony handle *is* the
	// authorization. It was issued to whoever passed the check in
	// /register/begin, it is single-use, and it expires in minutes.
	issued, err := s.passkeys.FinishRegistration(r.Context(), req.CeremonyID, req.Credential, req.Label)
	switch {
	case errors.Is(err, passkey.ErrCeremonyUnknown):
		s.fail(w, r, http.StatusBadRequest, "this registration has expired; start again", err)
		return
	case errors.Is(err, passkey.ErrVerification):
		s.fail(w, r, http.StatusBadRequest, "the authenticator's response did not verify", err)
		return
	case errors.Is(err, store.ErrCredentialClaimed):
		s.fail(w, r, http.StatusConflict, "that authenticator is already registered to another account", err)
		return
	case err != nil:
		s.fail(w, r, http.StatusInternalServerError, "could not finish registration", err)
		return
	}

	s.log.InfoContext(r.Context(), "passkey registered",
		"user_id", issued.UserID, "passkey_id", issued.PasskeyID)
	writeJSON(w, http.StatusOK, issued)
}

func (s *Server) handleLoginBegin(w http.ResponseWriter, r *http.Request) {
	if !s.passkeysEnabled(w, r) {
		return
	}
	ceremonyID, options, err := s.passkeys.BeginLogin(r.Context())
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not begin login", err)
		return
	}
	writeJSON(w, http.StatusOK, ceremonyResponse{CeremonyID: ceremonyID, Options: options})
}

func (s *Server) handleLoginFinish(w http.ResponseWriter, r *http.Request) {
	if !s.passkeysEnabled(w, r) {
		return
	}
	var req finishCeremonyRequest
	if !decodeJSON(s, w, r, &req) {
		return
	}
	if req.CeremonyID == "" || len(req.Credential) == 0 {
		s.fail(w, r, http.StatusBadRequest, "ceremony_id and credential are required", nil)
		return
	}

	issued, err := s.passkeys.FinishLogin(r.Context(), req.CeremonyID, req.Credential)
	switch {
	case errors.Is(err, passkey.ErrCeremonyUnknown):
		s.fail(w, r, http.StatusBadRequest, "this sign-in has expired; try again", err)
		return
	case errors.Is(err, passkey.ErrVerification):
		// Deliberately vague to the client, specific in the log: which half of
		// the check failed is not the caller's business.
		s.fail(w, r, http.StatusUnauthorized, "that passkey was not accepted", err)
		return
	case err != nil:
		s.fail(w, r, http.StatusInternalServerError, "could not finish login", err)
		return
	}

	s.log.InfoContext(r.Context(), "passkey login",
		"user_id", issued.UserID, "passkey_id", issued.PasskeyID)
	writeJSON(w, http.StatusOK, issued)
}

func (s *Server) handleWhoami(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"user_id": identity.UserID,
		"method":  identity.Method,
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	if identity.Method != auth.MethodSession {
		s.fail(w, r, http.StatusBadRequest,
			"only a passkey session can be logged out; a static token is revoked by changing the server's configuration", nil)
		return
	}
	if err := s.store.DeleteSession(r.Context(), identity.SessionToken); err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not log out", err)
		return
	}
	s.log.InfoContext(r.Context(), "logged out", "user_id", identity.UserID)
	w.WriteHeader(http.StatusNoContent)
}

// passkeyView is one registered authenticator, as shown to its owner. It
// deliberately carries no public key: there is nothing a user can do with it,
// and a list endpoint is a bad place to hand out key material.
type passkeyView struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	CreatedAt  string `json:"created_at"`
	LastUsedAt string `json:"last_used_at"`
}

func (s *Server) handleListPasskeys(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	stored, err := s.store.PasskeysByUser(r.Context(), identity.UserID)
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not list passkeys", err)
		return
	}
	views := make([]passkeyView, 0, len(stored))
	for _, p := range stored {
		views = append(views, passkeyView{
			ID: p.ID, Label: p.Label, CreatedAt: p.CreatedAt, LastUsedAt: p.LastUsedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"passkeys": views})
}

func (s *Server) handleDeletePasskey(w http.ResponseWriter, r *http.Request) {
	identity, err := s.auth.Authenticate(r)
	if err != nil {
		s.fail(w, r, http.StatusUnauthorized, "authentication failed", err)
		return
	}
	id := r.PathValue("id")
	if id == "" {
		s.fail(w, r, http.StatusBadRequest, "passkey id is required", nil)
		return
	}

	stored, err := s.store.PasskeyByID(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		s.fail(w, r, http.StatusNotFound, "no such passkey", nil)
		return
	}
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "could not read passkey", err)
		return
	}
	// Not found rather than forbidden: whether someone else's passkey exists
	// is not something to confirm.
	if stored.UserID != identity.UserID {
		s.fail(w, r, http.StatusNotFound, "no such passkey", nil)
		return
	}

	// The count, the delete and the session revocation happen in one
	// transaction inside the store: two concurrent removals must not each
	// conclude that a key is spare, and a credential must never outlive the
	// sessions it issued.
	err = s.store.DeletePasskey(r.Context(), id, identity.UserID)
	switch {
	case errors.Is(err, store.ErrLastPasskey):
		// There is no password to fall back on, so this would be a locked-out
		// account.
		s.fail(w, r, http.StatusConflict,
			"this is your only passkey; register another one before removing it", nil)
		return
	case errors.Is(err, store.ErrNotFound):
		s.fail(w, r, http.StatusNotFound, "no such passkey", nil)
		return
	case err != nil:
		s.fail(w, r, http.StatusInternalServerError, "could not delete passkey", err)
		return
	}
	s.log.InfoContext(r.Context(), "passkey removed", "user_id", identity.UserID, "passkey_id", id)
	w.WriteHeader(http.StatusNoContent)
}

// decodeJSON reads a JSON body, answering the request itself on failure.
func decodeJSON(s *Server, w http.ResponseWriter, r *http.Request, into any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(into); err != nil {
		s.fail(w, r, http.StatusBadRequest, "malformed request body", err)
		return false
	}
	return true
}
