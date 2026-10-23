// Package passkey implements giki's WebAuthn ceremonies: registering an
// authenticator and signing in with one.
//
// A successful ceremony issues an opaque bearer session token, which the
// client then sends on every sync request exactly like the static tokens that
// came before it. That is a deliberate choice over a session cookie: the sync
// API is a POST with a JSON body, and a cookie would make it reachable from
// any page the user visits -- a CSRF surface that a bearer token simply does
// not have, because a cross-origin page cannot read the token to send it.
package passkey

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/guettli/giki/internal/store"
)

// ErrCeremonyUnknown means the ceremony handle is unknown, already used or
// expired. All three are the same thing to a caller, and saying which would
// tell an attacker something.
var ErrCeremonyUnknown = errors.New("unknown or expired ceremony")

// ErrVerification means the authenticator's response did not verify.
var ErrVerification = errors.New("passkey verification failed")

// Config describes the relying party: this server, as the browser sees it.
type Config struct {
	// RPID is the domain the credential is bound to, without scheme or port,
	// e.g. "giki.example.org". A credential registered for one RPID cannot be
	// used on another, which is what makes passkeys unphishable.
	RPID string
	// DisplayName is shown by the authenticator while the user confirms.
	DisplayName string
	// Origins are the exact origins a ceremony may be performed at, e.g.
	// "https://giki.example.org". localhost origins are how this works in
	// development.
	Origins []string
}

// Service performs the ceremonies.
type Service struct {
	rp    *webauthn.WebAuthn
	store *store.Store
}

// New builds a Service.
func New(cfg Config, st *store.Store) (*Service, error) {
	if cfg.RPID == "" {
		return nil, errors.New("passkey: RPID is required")
	}
	if len(cfg.Origins) == 0 {
		return nil, errors.New("passkey: at least one origin is required")
	}
	if cfg.DisplayName == "" {
		cfg.DisplayName = "giki"
	}
	rp, err := webauthn.New(&webauthn.Config{
		RPID:          cfg.RPID,
		RPDisplayName: cfg.DisplayName,
		RPOrigins:     cfg.Origins,
	})
	if err != nil {
		return nil, fmt.Errorf("passkey: %w", err)
	}
	return &Service{rp: rp, store: st}, nil
}

// Issued is what a finished ceremony hands back.
type Issued struct {
	// Token is the bearer session token. It is shown exactly once.
	Token string `json:"token"`
	// UserID is who the session belongs to.
	UserID string `json:"user_id"`
	// ExpiresAt is when the session stops working.
	ExpiresAt string `json:"expires_at"`
	// PasskeyID identifies the credential that was used or created.
	PasskeyID string `json:"passkey_id"`
}

// webauthnUser adapts giki's two views of a user -- the WebAuthn record and
// the registered credentials -- to the library's interface.
type webauthnUser struct {
	user        store.PasskeyUser
	credentials []webauthn.Credential
}

func (u webauthnUser) WebAuthnID() []byte { return u.user.Handle }

// WebAuthnName is what the authenticator shows in its account picker, so it
// has to be the thing a human recognises: the user id.
func (u webauthnUser) WebAuthnName() string { return u.user.UserID }

func (u webauthnUser) WebAuthnDisplayName() string {
	if u.user.DisplayName != "" {
		return u.user.DisplayName
	}
	return u.user.UserID
}

func (u webauthnUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func (u webauthnUser) descriptors() []protocol.CredentialDescriptor {
	descriptors := make([]protocol.CredentialDescriptor, 0, len(u.credentials))
	for i := range u.credentials {
		descriptors = append(descriptors, u.credentials[i].Descriptor())
	}
	return descriptors
}

// loadUser assembles the WebAuthn user for userID, creating the WebAuthn
// record (and its random handle) if this is their first passkey.
func (s *Service) loadUser(ctx context.Context, userID, displayName string) (webauthnUser, error) {
	record, err := s.store.EnsurePasskeyUser(ctx, userID, displayName)
	if err != nil {
		return webauthnUser{}, err
	}
	return s.loadUserCredentials(ctx, record)
}

func (s *Service) loadUserCredentials(ctx context.Context, record store.PasskeyUser) (webauthnUser, error) {
	stored, err := s.store.PasskeysByUser(ctx, record.UserID)
	if err != nil {
		return webauthnUser{}, err
	}
	credentials := make([]webauthn.Credential, 0, len(stored))
	for _, p := range stored {
		var credential webauthn.Credential
		if err := json.Unmarshal(p.Credential, &credential); err != nil {
			return webauthnUser{}, fmt.Errorf("stored credential %s is unreadable: %w", p.ID, err)
		}
		credentials = append(credentials, credential)
	}
	return webauthnUser{user: record, credentials: credentials}, nil
}

// BeginRegistration starts registering a new authenticator for userID.
func (s *Service) BeginRegistration(ctx context.Context, userID, displayName string) (string, json.RawMessage, error) {
	user, err := s.loadUser(ctx, userID, displayName)
	if err != nil {
		return "", nil, err
	}

	creation, session, err := s.rp.BeginRegistration(user,
		// Ask for a discoverable credential: that is what makes the login
		// screen need no username at all.
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementRequired,
			UserVerification: protocol.VerificationPreferred,
		}),
		// Without the exclusion list an authenticator the user already
		// registered would silently create a second credential for the same
		// account.
		webauthn.WithExclusions(user.descriptors()),
	)
	if err != nil {
		return "", nil, fmt.Errorf("begin registration: %w", err)
	}

	encodedSession, err := json.Marshal(session)
	if err != nil {
		return "", nil, fmt.Errorf("encode session: %w", err)
	}
	ceremonyID, err := s.store.SaveCeremony(ctx, "register", userID, encodedSession)
	if err != nil {
		return "", nil, err
	}
	options, err := json.Marshal(creation.Response)
	if err != nil {
		return "", nil, fmt.Errorf("encode creation options: %w", err)
	}
	return ceremonyID, options, nil
}

// FinishRegistration verifies the authenticator's response, stores the
// credential and issues a session.
func (s *Service) FinishRegistration(ctx context.Context, ceremonyID string, response json.RawMessage, label string) (Issued, error) {
	userID, encodedSession, err := s.store.TakeCeremony(ctx, ceremonyID, "register")
	if errors.Is(err, store.ErrNotFound) {
		return Issued{}, ErrCeremonyUnknown
	}
	if err != nil {
		return Issued{}, err
	}

	var session webauthn.SessionData
	if err := json.Unmarshal(encodedSession, &session); err != nil {
		return Issued{}, fmt.Errorf("decode session: %w", err)
	}
	user, err := s.loadUser(ctx, userID, "")
	if err != nil {
		return Issued{}, err
	}

	parsed, err := protocol.ParseCredentialCreationResponseBytes(response)
	if err != nil {
		return Issued{}, fmt.Errorf("%w: %s", ErrVerification, err)
	}
	credential, err := s.rp.CreateCredential(user, session, parsed)
	if err != nil {
		return Issued{}, fmt.Errorf("%w: %s", ErrVerification, err)
	}

	encodedCredential, err := json.Marshal(credential)
	if err != nil {
		return Issued{}, fmt.Errorf("encode credential: %w", err)
	}
	id := base64.RawURLEncoding.EncodeToString(credential.ID)
	if err := s.store.SavePasskey(ctx, store.Passkey{
		ID:         id,
		UserID:     userID,
		Label:      label,
		Credential: encodedCredential,
	}); err != nil {
		return Issued{}, err
	}

	// Make the user visible in the app itself. Created once and never
	// overwritten, so registering a second passkey cannot undo a display name
	// the user has since changed.
	if err := s.store.EnsureSyncedUser(ctx, userID, user.WebAuthnDisplayName()); err != nil {
		return Issued{}, err
	}

	token, expiresAt, err := s.store.CreateSession(ctx, userID, id, label)
	if err != nil {
		return Issued{}, err
	}
	return Issued{Token: token, UserID: userID, ExpiresAt: expiresAt, PasskeyID: id}, nil
}

// BeginLogin starts a usernameless (discoverable) login.
func (s *Service) BeginLogin(ctx context.Context) (string, json.RawMessage, error) {
	assertion, session, err := s.rp.BeginDiscoverableLogin(
		webauthn.WithUserVerification(protocol.VerificationPreferred),
	)
	if err != nil {
		return "", nil, fmt.Errorf("begin login: %w", err)
	}

	encodedSession, err := json.Marshal(session)
	if err != nil {
		return "", nil, fmt.Errorf("encode session: %w", err)
	}
	ceremonyID, err := s.store.SaveCeremony(ctx, "login", "", encodedSession)
	if err != nil {
		return "", nil, err
	}
	options, err := json.Marshal(assertion.Response)
	if err != nil {
		return "", nil, fmt.Errorf("encode assertion options: %w", err)
	}
	return ceremonyID, options, nil
}

// FinishLogin verifies an assertion and issues a session.
func (s *Service) FinishLogin(ctx context.Context, ceremonyID string, response json.RawMessage) (Issued, error) {
	_, encodedSession, err := s.store.TakeCeremony(ctx, ceremonyID, "login")
	if errors.Is(err, store.ErrNotFound) {
		return Issued{}, ErrCeremonyUnknown
	}
	if err != nil {
		return Issued{}, err
	}

	var session webauthn.SessionData
	if err := json.Unmarshal(encodedSession, &session); err != nil {
		return Issued{}, fmt.Errorf("decode session: %w", err)
	}

	parsed, err := protocol.ParseCredentialRequestResponseBytes(response)
	if err != nil {
		return Issued{}, fmt.Errorf("%w: %s", ErrVerification, err)
	}

	// The authenticator tells us the handle; we have to find the account. This
	// is the whole point of a discoverable credential: the user typed nothing.
	var lookupErr error
	// rawID is unused: a discoverable login is resolved by user handle, and
	// the library refuses an assertion that arrives without one (WebAuthn L3
	// §7.2), so there is no credential-ID fallback to reach.
	handler := func(_, userHandle []byte) (webauthn.User, error) {
		record, err := s.store.PasskeyUserByHandle(ctx, userHandle)
		if errors.Is(err, store.ErrNotFound) {
			return nil, fmt.Errorf("%w: no account for this user handle", ErrVerification)
		}
		if err != nil {
			lookupErr = err
			return nil, err
		}
		user, err := s.loadUserCredentials(ctx, record)
		if err != nil {
			lookupErr = err
			return nil, err
		}
		return user, nil
	}

	_, credential, err := s.rp.ValidatePasskeyLogin(handler, session, parsed)
	if lookupErr != nil {
		return Issued{}, lookupErr
	}
	if err != nil {
		return Issued{}, fmt.Errorf("%w: %s", ErrVerification, err)
	}

	// The authenticator's signature counter went backwards (or stood still on
	// an authenticator that counts), which is what a cloned credential looks
	// like. Refuse rather than note it.
	if credential.Authenticator.CloneWarning {
		return Issued{}, fmt.Errorf("%w: the authenticator's signature counter did not advance", ErrVerification)
	}

	id := base64.RawURLEncoding.EncodeToString(credential.ID)
	stored, err := s.store.PasskeyByID(ctx, id)
	if errors.Is(err, store.ErrNotFound) {
		return Issued{}, fmt.Errorf("%w: unknown credential", ErrVerification)
	}
	if err != nil {
		return Issued{}, err
	}

	encodedCredential, err := json.Marshal(credential)
	if err != nil {
		return Issued{}, fmt.Errorf("encode credential: %w", err)
	}
	if err := s.store.TouchPasskey(ctx, id, encodedCredential); err != nil {
		return Issued{}, err
	}

	token, expiresAt, err := s.store.CreateSession(ctx, stored.UserID, id, stored.Label)
	if err != nil {
		return Issued{}, err
	}
	return Issued{Token: token, UserID: stored.UserID, ExpiresAt: expiresAt, PasskeyID: id}, nil
}
