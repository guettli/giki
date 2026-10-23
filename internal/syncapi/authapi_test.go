package syncapi

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"strings"
	"testing"

	"github.com/descope/virtualwebauthn"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/guettli/giki/internal/auth"
	"github.com/guettli/giki/internal/passkey"
	"github.com/guettli/giki/internal/store"
)

// These tests drive the real WebAuthn ceremonies against a virtual
// authenticator, so the signatures, the challenge binding and the sign
// counter are all genuinely exercised -- the parts that are easy to get
// subtly wrong and impossible to notice by hand.

const (
	registerToken = "let-me-in"
	rpID          = "localhost"
	rpOrigin      = "https://localhost"
)

type passkeyFixture struct {
	url    string
	client *http.Client
	store  *store.Store
	rp     virtualwebauthn.RelyingParty
}

func newPasskeyServer(t *testing.T) *passkeyFixture {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	service, err := passkey.New(passkey.Config{
		RPID:        rpID,
		DisplayName: "giki",
		Origins:     []string{rpOrigin},
	}, st)
	if err != nil {
		t.Fatalf("passkey.New: %v", err)
	}
	static, err := auth.ParseTokens("ops-token:operator")
	if err != nil {
		t.Fatalf("ParseTokens: %v", err)
	}

	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := New(st, auth.Chain{static, auth.NewSessions(st)}, quiet,
		WithPasskeys(service, registerToken))
	ts := newTestHTTPServer(t, server.Routes())

	return &passkeyFixture{
		url:    ts,
		client: &http.Client{},
		store:  st,
		rp:     virtualwebauthn.RelyingParty{ID: rpID, Name: "giki", Origin: rpOrigin},
	}
}

// do performs a JSON request and returns the status and the decoded body.
func (f *passkeyFixture) do(t *testing.T, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("encode body: %v", err)
		}
		reader = strings.NewReader(string(encoded))
	}
	req, err := http.NewRequest(method, f.url+path, reader)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := f.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	decoded := map[string]any{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			decoded = map[string]any{"_raw": string(raw)}
		}
	}
	return res.StatusCode, decoded
}

// register runs a full registration ceremony and returns the issued session
// token plus the credential the authenticator now holds.
func (f *passkeyFixture) register(t *testing.T, authenticator *virtualwebauthn.Authenticator,
	userID, displayName, authorization, label string,
) (string, virtualwebauthn.Credential) {
	t.Helper()
	status, body := f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", authorization,
		map[string]string{"user_id": userID, "display_name": displayName})
	if status != http.StatusOK {
		t.Fatalf("register/begin = %d: %v", status, body)
	}
	ceremonyID, _ := body["ceremony_id"].(string)
	options := mustEncode(t, body["options"])

	parsed, err := virtualwebauthn.ParseAttestationOptions(options)
	if err != nil {
		t.Fatalf("parse attestation options: %v (%s)", err, options)
	}
	credential := virtualwebauthn.NewCredential(virtualwebauthn.KeyTypeEC2)
	// Remember the handle the server minted for this account, so later
	// assertions carry it the way a real authenticator would. parsed.UserID is
	// the decoded handle, not the user id.
	if !authenticator.Options.UserNotPresent {
		authenticator.Options.UserHandle = []byte(parsed.UserID)
	}
	response := virtualwebauthn.CreateAttestationResponse(f.rp, *authenticator, credential, *parsed)

	status, body = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/finish", authorization,
		map[string]any{
			"ceremony_id": ceremonyID,
			"credential":  json.RawMessage(response),
			"label":       label,
		})
	if status != http.StatusOK {
		t.Fatalf("register/finish = %d: %v", status, body)
	}
	authenticator.AddCredential(credential)

	token, _ := body["token"].(string)
	if token == "" {
		t.Fatalf("register/finish returned no token: %v", body)
	}
	return token, credential
}

// login runs a full discoverable login and returns the issued session token.
func (f *passkeyFixture) login(t *testing.T, authenticator *virtualwebauthn.Authenticator) (int, string, map[string]any) {
	t.Helper()
	status, body := f.do(t, http.MethodPost, "/api/v1/auth/passkey/login/begin", "", nil)
	if status != http.StatusOK {
		t.Fatalf("login/begin = %d: %v", status, body)
	}
	ceremonyID, _ := body["ceremony_id"].(string)
	options := mustEncode(t, body["options"])

	parsed, err := virtualwebauthn.ParseAssertionOptions(options)
	if err != nil {
		t.Fatalf("parse assertion options: %v (%s)", err, options)
	}
	credential := residentCredential(t, authenticator, parsed)
	response := virtualwebauthn.CreateAssertionResponse(f.rp, *authenticator, *credential, *parsed)

	status, body = f.do(t, http.MethodPost, "/api/v1/auth/passkey/login/finish", "",
		map[string]any{"ceremony_id": ceremonyID, "credential": json.RawMessage(response)})
	token, _ := body["token"].(string)
	return status, token, body
}

// residentCredential picks the credential a real authenticator would use for a
// discoverable login: one it stored for this relying party.
//
// virtualwebauthn's FindAllowedCredential cannot help here -- it matches
// against allowCredentials, and a usernameless login deliberately sends an
// empty list. That is the whole point of a resident key.
func residentCredential(t *testing.T, authenticator *virtualwebauthn.Authenticator,
	options *virtualwebauthn.AssertionOptions,
) *virtualwebauthn.Credential {
	t.Helper()
	if options.RelyingPartyID != rpID {
		t.Fatalf("login options are for relying party %q, want %q", options.RelyingPartyID, rpID)
	}
	if len(options.AllowCredentials) != 0 {
		t.Fatalf("a discoverable login must not restrict credentials, got %v", options.AllowCredentials)
	}
	if len(authenticator.Credentials) == 0 {
		t.Fatal("the authenticator holds no credentials")
	}
	return &authenticator.Credentials[len(authenticator.Credentials)-1]
}

func mustEncode(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("re-encode: %v", err)
	}
	return string(encoded)
}

func TestPasskeyRegisterThenLogin(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()

	sessionToken, _ := f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	// The session works on the API, and says who it belongs to.
	status, body := f.do(t, http.MethodGet, "/api/v1/auth/whoami", sessionToken, nil)
	if status != http.StatusOK {
		t.Fatalf("whoami = %d: %v", status, body)
	}
	if body["user_id"] != "alice" || body["method"] != auth.MethodSession {
		t.Errorf("whoami = %v, want alice via a session", body)
	}

	// Registration created the app-level user, and it is on its way to every
	// client as an ordinary delta.
	var displayName string
	if err := f.store.DB.QueryRow(`SELECT display_name FROM users WHERE id = 'alice'`).Scan(&displayName); err != nil {
		t.Fatalf("registration did not create the synced user: %v", err)
	}
	if displayName != "Alice" {
		t.Errorf("display_name = %q, want Alice", displayName)
	}

	// A fresh login with the same authenticator issues a different session.
	status, loginToken, body := f.login(t, &authenticator)
	if status != http.StatusOK {
		t.Fatalf("login = %d: %v", status, body)
	}
	if loginToken == sessionToken {
		t.Error("login reissued the same token; sessions must be distinct")
	}
	if body["user_id"] != "alice" {
		t.Errorf("login user_id = %v, want alice", body["user_id"])
	}

	// Logging in usernameless means the server resolved the user from the
	// credential alone -- nothing in the login request named alice.
	status, body = f.do(t, http.MethodGet, "/api/v1/auth/whoami", loginToken, nil)
	if status != http.StatusOK || body["user_id"] != "alice" {
		t.Errorf("whoami after login = %d %v", status, body)
	}
}

func TestPasskeySessionAuthenticatesSync(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	sessionToken, _ := f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	// Push a node with the passkey session rather than a static token.
	payload, _ := json.Marshal(map[string]any{
		"id": "n1", "title": "Leitner", "title_key": "leitner", "body": "boxes",
		"created_at": "2026-10-23T10:00:00.000Z", "updated_at": "2026-10-23T10:00:00.000Z",
		"is_deleted": 0,
	})
	status, body := f.do(t, http.MethodPost, "/api/v1/sync", sessionToken, SyncRequest{
		DeviceID: "phone-a",
		Mutations: []store.Mutation{{
			ClientSeq: 1, Table: "nodes", RecordID: "n1", Op: "INSERT",
			UpdatedAt: "2026-10-23T10:00:00.000Z", Payload: payload,
		}},
	})
	if status != http.StatusOK {
		t.Fatalf("sync with a session = %d: %v", status, body)
	}

	// The audit trail records the user the session belongs to, which is the
	// whole reason the session carries a user id at all.
	history, err := f.store.RecordHistory(t.Context(), "nodes", "n1", 0)
	if err != nil {
		t.Fatalf("RecordHistory: %v", err)
	}
	if len(history) != 1 || history[0].ActorUserID != "alice" {
		t.Fatalf("history = %+v, want one entry authored by alice", history)
	}

	// Logging out kills the session immediately.
	status, body = f.do(t, http.MethodPost, "/api/v1/auth/logout", sessionToken, nil)
	if status != http.StatusNoContent {
		t.Fatalf("logout = %d: %v", status, body)
	}
	if status, _ := f.do(t, http.MethodGet, "/api/v1/auth/whoami", sessionToken, nil); status != http.StatusUnauthorized {
		t.Errorf("whoami after logout = %d, want 401", status)
	}
}

func TestPasskeyRegistrationIsGated(t *testing.T) {
	f := newPasskeyServer(t)

	// No token at all.
	status, _ := f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", "",
		map[string]string{"user_id": "intruder"})
	if status != http.StatusUnauthorized {
		t.Errorf("register without a token = %d, want 401", status)
	}

	// Wrong token.
	status, _ = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", "not-the-token",
		map[string]string{"user_id": "intruder"})
	if status != http.StatusUnauthorized {
		t.Errorf("register with a wrong token = %d, want 401", status)
	}

	// The registration token requires a user id: there is no session to infer
	// one from.
	status, _ = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", registerToken,
		map[string]string{})
	if status != http.StatusBadRequest {
		t.Errorf("register without a user_id = %d, want 400", status)
	}
}

func TestPasskeySessionCannotRegisterForAnotherUser(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	sessionToken, _ := f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	// Alice is signed in, so she may add her own keys...
	status, _ := f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", sessionToken,
		map[string]string{"user_id": "alice"})
	if status != http.StatusOK {
		t.Errorf("alice adding her own passkey = %d, want 200", status)
	}

	// ...but not a key against somebody else's account.
	status, body := f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", sessionToken,
		map[string]string{"user_id": "bob"})
	if status != http.StatusForbidden {
		t.Errorf("alice registering for bob = %d, want 403 (%v)", status, body)
	}

	// A static operator token is an identity too, and the same rule applies.
	status, _ = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", "ops-token",
		map[string]string{"user_id": "alice"})
	if status != http.StatusForbidden {
		t.Errorf("operator registering for alice = %d, want 403", status)
	}
}

func TestPasskeyCeremonyIsSingleUse(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()

	status, body := f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/begin", registerToken,
		map[string]string{"user_id": "alice"})
	if status != http.StatusOK {
		t.Fatalf("register/begin = %d: %v", status, body)
	}
	ceremonyID, _ := body["ceremony_id"].(string)
	parsed, err := virtualwebauthn.ParseAttestationOptions(mustEncode(t, body["options"]))
	if err != nil {
		t.Fatalf("parse options: %v", err)
	}
	credential := virtualwebauthn.NewCredential(virtualwebauthn.KeyTypeEC2)
	response := virtualwebauthn.CreateAttestationResponse(f.rp, authenticator, credential, *parsed)

	finish := map[string]any{"ceremony_id": ceremonyID, "credential": json.RawMessage(response)}
	if status, body = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/finish", registerToken, finish); status != http.StatusOK {
		t.Fatalf("first finish = %d: %v", status, body)
	}
	// Replaying the identical response must not produce a second credential:
	// the challenge is gone.
	if status, _ = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/finish", registerToken, finish); status != http.StatusBadRequest {
		t.Errorf("replayed finish = %d, want 400", status)
	}

	// Same for an unknown handle.
	finish["ceremony_id"] = "made-up"
	if status, _ = f.do(t, http.MethodPost, "/api/v1/auth/passkey/register/finish", registerToken, finish); status != http.StatusBadRequest {
		t.Errorf("unknown ceremony = %d, want 400", status)
	}
}

func TestPasskeyLoginRejectsAnotherRelyingParty(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	// An assertion produced for a different origin -- what a phishing site
	// would collect -- must not be accepted.
	status, body := f.do(t, http.MethodPost, "/api/v1/auth/passkey/login/begin", "", nil)
	if status != http.StatusOK {
		t.Fatalf("login/begin = %d: %v", status, body)
	}
	ceremonyID, _ := body["ceremony_id"].(string)
	parsed, err := virtualwebauthn.ParseAssertionOptions(mustEncode(t, body["options"]))
	if err != nil {
		t.Fatalf("parse options: %v", err)
	}
	credential := residentCredential(t, &authenticator, parsed)
	evil := virtualwebauthn.RelyingParty{ID: "evil.example", Name: "evil", Origin: "https://evil.example"}
	response := virtualwebauthn.CreateAssertionResponse(evil, authenticator, *credential, *parsed)

	status, body = f.do(t, http.MethodPost, "/api/v1/auth/passkey/login/finish", "",
		map[string]any{"ceremony_id": ceremonyID, "credential": json.RawMessage(response)})
	if status != http.StatusUnauthorized {
		t.Errorf("assertion from another origin = %d, want 401 (%v)", status, body)
	}
}

func TestPasskeyListAndDelete(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	sessionToken, _ := f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	status, body := f.do(t, http.MethodGet, "/api/v1/auth/passkeys", sessionToken, nil)
	if status != http.StatusOK {
		t.Fatalf("list = %d: %v", status, body)
	}
	list, _ := body["passkeys"].([]any)
	if len(list) != 1 {
		t.Fatalf("list has %d passkeys, want 1", len(list))
	}
	first, _ := list[0].(map[string]any)
	if first["label"] != "laptop" {
		t.Errorf("label = %v, want laptop", first["label"])
	}
	if _, leaked := first["credential"]; leaked {
		t.Error("the list endpoint returned key material")
	}
	onlyID, _ := first["id"].(string)

	// The only passkey cannot be removed: there is no password to fall back
	// on, so this would be a locked-out account.
	if status, _ = f.do(t, http.MethodDelete, "/api/v1/auth/passkeys/"+onlyID, sessionToken, nil); status != http.StatusConflict {
		t.Errorf("deleting the only passkey = %d, want 409", status)
	}

	// With a second one registered, removing the first is allowed, and the
	// sessions it issued die with it.
	secondToken, _ := f.register(t, &authenticator, "alice", "", sessionToken, "phone")
	if status, _ = f.do(t, http.MethodDelete, "/api/v1/auth/passkeys/"+onlyID, secondToken, nil); status != http.StatusNoContent {
		t.Fatalf("deleting a passkey = %d, want 204", status)
	}
	if status, _ = f.do(t, http.MethodGet, "/api/v1/auth/whoami", sessionToken, nil); status != http.StatusUnauthorized {
		t.Errorf("session of a removed passkey = %d, want 401", status)
	}
	if status, _ = f.do(t, http.MethodGet, "/api/v1/auth/whoami", secondToken, nil); status != http.StatusOK {
		t.Errorf("the surviving session = %d, want 200", status)
	}

	// Somebody else's passkey is invisible rather than forbidden.
	if status, _ = f.do(t, http.MethodDelete, "/api/v1/auth/passkeys/"+onlyID, secondToken, nil); status != http.StatusNotFound {
		t.Errorf("deleting an unknown passkey = %d, want 404", status)
	}
}

func TestPasskeyDisabledWithoutConfiguration(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	defer st.Close()
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	ts := newTestHTTPServer(t, New(st, auth.OpenDev{UserID: "alice"}, quiet).Routes())

	f := &passkeyFixture{url: ts, client: &http.Client{}, store: st}
	status, body := f.do(t, http.MethodPost, "/api/v1/auth/passkey/login/begin", "", nil)
	if status != http.StatusNotImplemented {
		t.Errorf("login on a server without passkeys = %d, want 501 (%v)", status, body)
	}
	// The message has to point at the flag, or an operator is left guessing.
	if message, _ := body["error"].(string); !strings.Contains(message, "-passkey-domain") {
		t.Errorf("error = %q, want it to name the flag", message)
	}
}

// credentialJSON is a shape check: whatever the browser sends must be what the
// library parses, and this is the one place both sides are visible together.
func TestVirtualAuthenticatorProducesParseableCredential(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	_, credential := f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	stored, err := f.store.PasskeysByUser(t.Context(), "alice")
	if err != nil {
		t.Fatalf("PasskeysByUser: %v", err)
	}
	if len(stored) != 1 {
		t.Fatalf("stored %d passkeys, want 1", len(stored))
	}
	var decoded webauthn.Credential
	if err := json.Unmarshal(stored[0].Credential, &decoded); err != nil {
		t.Fatalf("stored credential does not round-trip: %v", err)
	}
	if got, want := fmt.Sprintf("%x", decoded.ID), fmt.Sprintf("%x", credential.ID); got != want {
		t.Errorf("stored credential id = %s, want %s", got, want)
	}
	if len(decoded.PublicKey) == 0 {
		t.Error("stored credential has no public key")
	}
}

// TestPasskeyLoginWithoutUserHandle pins down what happens when an
// authenticator returns a blank user handle: the login is refused.
//
// Worth a test because it is tempting to "fix" by falling back to the
// credential ID. The WebAuthn spec requires the handle for a client-side
// discoverable credential, and go-webauthn enforces that before our handler
// ever runs -- so such a fallback would be unreachable code that looks load
// bearing.
func TestPasskeyLoginWithoutUserHandle(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	authenticator.Options.UserHandle = nil

	status, _, body := f.login(t, &authenticator)
	if status != http.StatusUnauthorized {
		t.Errorf("login with a blank user handle = %d, want 401 (%v)", status, body)
	}
}

// TestPasskeyLoginRejectsUnknownCredential is the other half: a syntactically
// valid assertion from an authenticator this server has never seen.
func TestPasskeyLoginRejectsUnknownCredential(t *testing.T) {
	f := newPasskeyServer(t)
	authenticator := virtualwebauthn.NewAuthenticator()
	f.register(t, &authenticator, "alice", "Alice", registerToken, "laptop")

	stranger := virtualwebauthn.NewAuthenticator()
	stranger.AddCredential(virtualwebauthn.NewCredential(virtualwebauthn.KeyTypeEC2))

	status, _, body := f.login(t, &stranger)
	if status != http.StatusUnauthorized {
		t.Errorf("login with an unregistered credential = %d, want 401 (%v)", status, body)
	}
}
