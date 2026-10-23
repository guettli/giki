package auth

import (
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/guettli/giki/internal/store"
)

// Method names how a request was authenticated. It ends up in the log, which
// is the point: "who was this" and "how did they prove it" are different
// questions.
const (
	// MethodStaticToken is a token from -tokens: for operators and scripts.
	MethodStaticToken = "token"
	// MethodSession is a session issued by a passkey ceremony.
	MethodSession = "session"
	// MethodDev is -dev-user, which proves nothing.
	MethodDev = "dev"
)

// Sessions authenticates the bearer sessions that passkey logins issue.
type Sessions struct {
	store *store.Store
}

// NewSessions builds a session authenticator.
func NewSessions(st *store.Store) *Sessions { return &Sessions{store: st} }

// Authenticate resolves an "Authorization: Bearer <session>" header.
//
// An unknown token is not an error worth distinguishing from an expired one:
// both mean "sign in again", and telling them apart would tell an attacker
// which tokens once existed.
func (s *Sessions) Authenticate(r *http.Request) (Identity, error) {
	token, ok := bearer(r)
	if !ok {
		return Identity{}, fmt.Errorf("%w: missing bearer token", ErrUnauthorized)
	}
	session, err := s.store.LookupSession(r.Context(), token)
	if errors.Is(err, store.ErrNotFound) {
		return Identity{}, fmt.Errorf("%w: no such session", ErrUnauthorized)
	}
	if err != nil {
		return Identity{}, err
	}
	return Identity{
		UserID:       session.UserID,
		Method:       MethodSession,
		SessionToken: token,
	}, nil
}

// Chain tries each authenticator in order and takes the first that succeeds.
//
// This is how a passkey session and an operator's static token can both work
// on the same endpoint without either knowing about the other.
type Chain []Authenticator

// Authenticate returns the first successful identity.
func (c Chain) Authenticate(r *http.Request) (Identity, error) {
	var firstErr error
	for _, authenticator := range c {
		identity, err := authenticator.Authenticate(r)
		if err == nil {
			return identity, nil
		}
		// A real failure (the database is down) must not be reported as "your
		// credentials are wrong", so it wins over any later Unauthorized.
		if !errors.Is(err, ErrUnauthorized) {
			return Identity{}, err
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	if firstErr == nil {
		firstErr = fmt.Errorf("%w: no authenticator configured", ErrUnauthorized)
	}
	return Identity{}, firstErr
}

// bearer extracts a bearer token from the Authorization header.
func bearer(r *http.Request) (string, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}
