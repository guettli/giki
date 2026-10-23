// Package auth answers one question for every request: which user is this?
//
// giki's audit trail is only worth something if the user ID attached to a
// change comes from the session rather than from the payload, so every handler
// goes through here -- including in dev mode, where the answer is a constant.
package auth

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

// ErrUnauthorized is returned when a request carries no usable credential.
var ErrUnauthorized = errors.New("unauthorized")

// Identity is the authenticated caller.
type Identity struct {
	UserID string
}

// Authenticator turns a request into an Identity.
type Authenticator interface {
	Authenticate(r *http.Request) (Identity, error)
}

// StaticTokens maps bearer tokens to user IDs. It is deliberately the whole of
// giki's authentication for now: a self-hosted single-binary server with a
// handful of known users does not need accounts, sessions and password resets
// before it needs to sync correctly.
//
// TODO: replace with real accounts (registration, rotation, revocation) before
// exposing an instance to users who do not all trust each other.
type StaticTokens struct {
	pairs []tokenPair
}

type tokenPair struct {
	token  string
	userID string
}

// ParseTokens reads a "token:user,token:user" specification, as passed via
// -tokens or the GIKI_TOKENS environment variable.
func ParseTokens(spec string) (*StaticTokens, error) {
	st := &StaticTokens{}
	for _, entry := range strings.Split(spec, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		token, userID, ok := strings.Cut(entry, ":")
		if !ok || token == "" || userID == "" {
			return nil, fmt.Errorf("token spec %q is not token:user", entry)
		}
		st.pairs = append(st.pairs, tokenPair{token: token, userID: userID})
	}
	if len(st.pairs) == 0 {
		return nil, errors.New("token spec is empty")
	}
	return st, nil
}

// Authenticate reads an "Authorization: Bearer <token>" header.
func (s *StaticTokens) Authenticate(r *http.Request) (Identity, error) {
	header := r.Header.Get("Authorization")
	token, ok := strings.CutPrefix(header, "Bearer ")
	if !ok {
		return Identity{}, fmt.Errorf("%w: missing bearer token", ErrUnauthorized)
	}
	token = strings.TrimSpace(token)
	// Compared against every pair in constant time: a timing side channel here
	// would leak the token one byte at a time.
	match := ""
	for _, p := range s.pairs {
		if subtle.ConstantTimeCompare([]byte(p.token), []byte(token)) == 1 {
			match = p.userID
		}
	}
	if match == "" {
		return Identity{}, fmt.Errorf("%w: unknown token", ErrUnauthorized)
	}
	return Identity{UserID: match}, nil
}

// OpenDev authenticates every request as the same user. Insecure by design and
// only reachable via -dev-user, which logs a warning on startup.
type OpenDev struct {
	UserID string
}

// Authenticate always succeeds.
func (d OpenDev) Authenticate(*http.Request) (Identity, error) {
	return Identity{UserID: d.UserID}, nil
}
