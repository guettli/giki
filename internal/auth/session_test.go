package auth

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/guettli/giki/internal/store"
)

func testStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

func request(token string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/sync", nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	return r
}

func TestSessionsAuthenticate(t *testing.T) {
	st := testStore(t)
	sessions := NewSessions(st)

	token, _, err := st.CreateSession(t.Context(), "alice", "passkey-1", "laptop")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	identity, err := sessions.Authenticate(request(token))
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if identity.UserID != "alice" || identity.Method != MethodSession {
		t.Errorf("identity = %+v, want alice via a session", identity)
	}
	if identity.SessionToken != token {
		t.Error("the identity does not carry the session, so logout could not revoke it")
	}

	for _, bad := range []string{"", "not-a-session"} {
		if _, err := sessions.Authenticate(request(bad)); !errors.Is(err, ErrUnauthorized) {
			t.Errorf("Authenticate(%q) error = %v, want ErrUnauthorized", bad, err)
		}
	}
}

func TestSessionsRejectExpired(t *testing.T) {
	st := testStore(t)
	sessions := NewSessions(st)

	token, _, err := st.CreateSession(t.Context(), "alice", "passkey-1", "laptop")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	if _, err := st.DB.Exec(
		`UPDATE api_sessions SET expires_at = '2020-01-01T00:00:00.000Z' WHERE token_sha256 = ?`,
		store.HashToken(token)); err != nil {
		t.Fatalf("age the session: %v", err)
	}

	if _, err := sessions.Authenticate(request(token)); !errors.Is(err, ErrUnauthorized) {
		t.Errorf("an expired session authenticated: %v", err)
	}
	// And it is gone, so the table does not grow forever.
	var remaining int
	if err := st.DB.QueryRow(`SELECT COUNT(*) FROM api_sessions`).Scan(&remaining); err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if remaining != 0 {
		t.Errorf("%d expired sessions left behind, want 0", remaining)
	}
}

// failing stands in for an authenticator whose backing store is broken, as
// opposed to a credential that is simply wrong.
type failing struct{ err error }

func (f failing) Authenticate(*http.Request) (Identity, error) { return Identity{}, f.err }

func TestChain(t *testing.T) {
	static, err := ParseTokens("ops:operator")
	if err != nil {
		t.Fatalf("ParseTokens: %v", err)
	}
	st := testStore(t)
	session, _, err := st.CreateSession(t.Context(), "alice", "passkey-1", "")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	chain := Chain{static, NewSessions(st)}

	// Either credential works on the same endpoint, which is the point of the
	// chain: the sync handlers do not care which one a request brought.
	for token, want := range map[string]string{"ops": "operator", session: "alice"} {
		identity, err := chain.Authenticate(request(token))
		if err != nil {
			t.Fatalf("Authenticate(%s): %v", want, err)
		}
		if identity.UserID != want {
			t.Errorf("identity = %q, want %q", identity.UserID, want)
		}
	}

	if _, err := chain.Authenticate(request("neither")); !errors.Is(err, ErrUnauthorized) {
		t.Errorf("unknown credential error = %v, want ErrUnauthorized", err)
	}
	if _, err := (Chain{}).Authenticate(request("anything")); !errors.Is(err, ErrUnauthorized) {
		t.Error("an empty chain must not authenticate anybody")
	}
}

func TestChainPrefersRealFailuresOverUnauthorized(t *testing.T) {
	broken := errors.New("database is locked")

	// A broken dependency must not be reported as "your credentials are
	// wrong": that would turn an outage into a mass logout, and would hide the
	// actual fault.
	chain := Chain{failing{err: broken}, OpenDev{UserID: "alice"}}
	if _, err := chain.Authenticate(request("x")); !errors.Is(err, broken) {
		t.Errorf("error = %v, want the underlying failure", err)
	}

	// The reverse order is what makes OpenDev last in buildAuth: it accepts
	// everything, so nothing after it is reachable.
	chain = Chain{OpenDev{UserID: "alice"}, failing{err: broken}}
	identity, err := chain.Authenticate(request("x"))
	if err != nil || identity.UserID != "alice" {
		t.Errorf("identity = %+v, err = %v; want alice", identity, err)
	}
}
