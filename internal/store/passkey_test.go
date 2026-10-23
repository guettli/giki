package store

import (
	"errors"
	"testing"
)

func TestCeremonyIsSingleUseAndKindChecked(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	handle, err := st.SaveCeremony(ctx, "register", "alice", []byte(`{"challenge":"abc"}`))
	if err != nil {
		t.Fatalf("SaveCeremony: %v", err)
	}

	// The handle is a bearer capability for an unauthenticated endpoint, so
	// only its hash may be stored.
	var stored string
	if err := st.DB.QueryRow(`SELECT id FROM passkey_ceremonies`).Scan(&stored); err != nil {
		t.Fatalf("read ceremony: %v", err)
	}
	if stored == handle {
		t.Error("the ceremony handle is stored in plaintext")
	}
	if stored != HashToken(handle) {
		t.Error("the stored ceremony id is not the handle's hash")
	}

	// A login response must not finish a registration ceremony.
	if _, _, err := st.TakeCeremony(ctx, handle, "login"); !errors.Is(err, ErrNotFound) {
		t.Errorf("wrong-kind take = %v, want ErrNotFound", err)
	}
	// ...and that attempt consumed it, so it cannot be retried as the right
	// kind either. Single use means single use.
	if _, _, err := st.TakeCeremony(ctx, handle, "register"); !errors.Is(err, ErrNotFound) {
		t.Errorf("take after a wrong-kind attempt = %v, want ErrNotFound", err)
	}

	handle, err = st.SaveCeremony(ctx, "login", "", []byte(`{"challenge":"def"}`))
	if err != nil {
		t.Fatalf("SaveCeremony: %v", err)
	}
	if _, _, err := st.TakeCeremony(ctx, handle, "login"); err != nil {
		t.Fatalf("first take: %v", err)
	}
	if _, _, err := st.TakeCeremony(ctx, handle, "login"); !errors.Is(err, ErrNotFound) {
		t.Errorf("replayed take = %v, want ErrNotFound", err)
	}
	if _, _, err := st.TakeCeremony(ctx, "never-issued", "login"); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown handle = %v, want ErrNotFound", err)
	}
	if _, err := st.SaveCeremony(ctx, "something-else", "", nil); err == nil {
		t.Error("SaveCeremony accepted an unknown kind")
	}
}

func TestCeremonyExpires(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	handle, err := st.SaveCeremony(ctx, "login", "", []byte(`{}`))
	if err != nil {
		t.Fatalf("SaveCeremony: %v", err)
	}
	if _, err := st.DB.Exec(
		`UPDATE passkey_ceremonies SET expires_at = '2020-01-01T00:00:00.000Z' WHERE id = ?`,
		HashToken(handle)); err != nil {
		t.Fatalf("age the ceremony: %v", err)
	}
	if _, _, err := st.TakeCeremony(ctx, handle, "login"); !errors.Is(err, ErrNotFound) {
		t.Errorf("expired ceremony = %v, want ErrNotFound", err)
	}
}

func TestSavePasskeyDoesNotMoveCredentialsBetweenUsers(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	if err := st.SavePasskey(ctx, Passkey{
		ID: "CRED-1", UserID: "alice", Label: "laptop", Credential: []byte(`{"id":"x"}`),
	}); err != nil {
		t.Fatalf("SavePasskey: %v", err)
	}

	// The credential id comes from attested data that nothing vouches for, so
	// claiming somebody else's must be refused rather than honoured.
	err := st.SavePasskey(ctx, Passkey{
		ID: "CRED-1", UserID: "bob", Label: "thief", Credential: []byte(`{"id":"y"}`),
	})
	if !errors.Is(err, ErrCredentialClaimed) {
		t.Fatalf("stealing a credential = %v, want ErrCredentialClaimed", err)
	}

	alice, err := st.PasskeysByUser(ctx, "alice")
	if err != nil {
		t.Fatalf("PasskeysByUser: %v", err)
	}
	if len(alice) != 1 || alice[0].Label != "laptop" {
		t.Errorf("alice's passkeys = %+v, want her original one", alice)
	}
	bob, err := st.PasskeysByUser(ctx, "bob")
	if err != nil {
		t.Fatalf("PasskeysByUser: %v", err)
	}
	if len(bob) != 0 {
		t.Errorf("bob gained %d passkeys", len(bob))
	}

	// The same owner re-registering the same authenticator is fine: it
	// refreshes the key material.
	if err := st.SavePasskey(ctx, Passkey{
		ID: "CRED-1", UserID: "alice", Label: "laptop again", Credential: []byte(`{"id":"z"}`),
	}); err != nil {
		t.Fatalf("re-registering own credential: %v", err)
	}
	alice, _ = st.PasskeysByUser(ctx, "alice")
	if len(alice) != 1 || alice[0].Label != "laptop again" {
		t.Errorf("re-registration did not update: %+v", alice)
	}
}

func TestDeletePasskeyGuardsAndRevokes(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	for _, id := range []string{"CRED-1", "CRED-2"} {
		if err := st.SavePasskey(ctx, Passkey{ID: id, UserID: "alice", Credential: []byte(`{}`)}); err != nil {
			t.Fatalf("SavePasskey: %v", err)
		}
	}
	first, _, err := st.CreateSession(ctx, "alice", "CRED-1", "")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	second, _, err := st.CreateSession(ctx, "alice", "CRED-2", "")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}

	// Somebody else's credential is not theirs to remove, and the refusal
	// looks the same as one that does not exist.
	if err := st.DeletePasskey(ctx, "CRED-1", "bob"); !errors.Is(err, ErrNotFound) {
		t.Errorf("deleting another user's passkey = %v, want ErrNotFound", err)
	}

	if err := st.DeletePasskey(ctx, "CRED-1", "alice"); err != nil {
		t.Fatalf("DeletePasskey: %v", err)
	}
	// The sessions that credential issued die with it; the others live.
	if _, err := st.LookupSession(ctx, first); !errors.Is(err, ErrNotFound) {
		t.Error("a removed passkey left its session alive")
	}
	if _, err := st.LookupSession(ctx, second); err != nil {
		t.Errorf("an unrelated session was revoked: %v", err)
	}

	// The last one stays: there is no password to fall back on.
	if err := st.DeletePasskey(ctx, "CRED-2", "alice"); !errors.Is(err, ErrLastPasskey) {
		t.Errorf("deleting the last passkey = %v, want ErrLastPasskey", err)
	}
	remaining, _ := st.PasskeysByUser(ctx, "alice")
	if len(remaining) != 1 {
		t.Errorf("alice has %d passkeys, want her last one intact", len(remaining))
	}
}

func TestEnsurePasskeyUserIsStable(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	first, err := st.EnsurePasskeyUser(ctx, "alice", "Alice")
	if err != nil {
		t.Fatalf("EnsurePasskeyUser: %v", err)
	}
	if len(first.Handle) != 32 {
		t.Errorf("handle is %d bytes, want 32 random ones", len(first.Handle))
	}

	// The handle must not change, or the passkeys already registered against
	// it would stop resolving.
	again, err := st.EnsurePasskeyUser(ctx, "alice", "Alice Renamed")
	if err != nil {
		t.Fatalf("EnsurePasskeyUser: %v", err)
	}
	if string(again.Handle) != string(first.Handle) {
		t.Error("the user handle changed between registrations")
	}
	if again.DisplayName != "Alice Renamed" {
		t.Errorf("display name = %q, want the updated one", again.DisplayName)
	}

	byHandle, err := st.PasskeyUserByHandle(ctx, first.Handle)
	if err != nil {
		t.Fatalf("PasskeyUserByHandle: %v", err)
	}
	if byHandle.UserID != "alice" {
		t.Errorf("handle resolved to %q, want alice", byHandle.UserID)
	}
	if _, err := st.PasskeyUserByHandle(ctx, []byte("not-a-handle")); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown handle = %v, want ErrNotFound", err)
	}

	// A WebAuthn record without credentials is an abandoned registration, not
	// an account: beginning a ceremony creates the record, and dismissing the
	// browser prompt leaves it behind. Treating that as "the account exists"
	// would reserve the name forever -- refused as taken, impossible to sign
	// into.
	if taken, err := st.UserHasPasskey(ctx, "alice"); err != nil || taken {
		t.Errorf("UserHasPasskey(alice) = %v, %v; want false before any credential", taken, err)
	}
	if err := st.SavePasskey(ctx, Passkey{ID: "CRED-A", UserID: "alice", Credential: []byte(`{}`)}); err != nil {
		t.Fatalf("SavePasskey: %v", err)
	}
	if taken, err := st.UserHasPasskey(ctx, "alice"); err != nil || !taken {
		t.Errorf("UserHasPasskey(alice) = %v, %v; want true once she has one", taken, err)
	}
	if taken, _ := st.UserHasPasskey(ctx, "nobody"); taken {
		t.Error("UserHasPasskey invented an account")
	}
	if _, err := st.EnsurePasskeyUser(ctx, "", ""); err == nil {
		t.Error("EnsurePasskeyUser accepted an empty user id")
	}
}

func TestEnsureSyncedUser(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	if err := st.EnsureSyncedUser(ctx, "alice", "Alice"); err != nil {
		t.Fatalf("EnsureSyncedUser: %v", err)
	}
	// It goes through the ChangeLog, so every client learns about it as an
	// ordinary delta rather than never.
	history, err := st.RecordHistory(ctx, "users", "alice", 0)
	if err != nil {
		t.Fatalf("RecordHistory: %v", err)
	}
	if len(history) != 1 {
		t.Fatalf("change_log has %d entries for the new user, want 1", len(history))
	}

	// A second registration must not undo a display name the user has since
	// changed in the app.
	if _, err := st.DB.Exec(
		`UPDATE users SET display_name = 'Alice In The App', updated_at = ? WHERE id = 'alice'`,
		Now()); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if err := st.EnsureSyncedUser(ctx, "alice", "Alice"); err != nil {
		t.Fatalf("EnsureSyncedUser: %v", err)
	}
	var name string
	if err := st.DB.QueryRow(`SELECT display_name FROM users WHERE id = 'alice'`).Scan(&name); err != nil {
		t.Fatalf("read user: %v", err)
	}
	if name != "Alice In The App" {
		t.Errorf("display_name = %q, want the app's value kept", name)
	}

	// A user who was deleted in the app and registers again must come back.
	// Otherwise they can authenticate and write while being a nameless
	// tombstone in everybody's copy.
	if _, err := st.DB.Exec(`UPDATE users SET is_deleted = 1 WHERE id = 'alice'`); err != nil {
		t.Fatalf("tombstone: %v", err)
	}
	if err := st.EnsureSyncedUser(ctx, "alice", "Alice Again"); err != nil {
		t.Fatalf("EnsureSyncedUser after deletion: %v", err)
	}
	var deleted int
	if err := st.DB.QueryRow(
		`SELECT is_deleted, display_name FROM users WHERE id = 'alice'`).Scan(&deleted, &name); err != nil {
		t.Fatalf("read user: %v", err)
	}
	if deleted != 0 || name != "Alice Again" {
		t.Errorf("user is_deleted=%d display_name=%q, want a live, named user", deleted, name)
	}
}

func TestSessionLifecycle(t *testing.T) {
	st := openTestStore(t)
	ctx := t.Context()

	token, expiresAt, err := st.CreateSession(ctx, "alice", "CRED-1", "laptop")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	if expiresAt <= Now() {
		t.Errorf("expires_at = %q, which is already past", expiresAt)
	}

	// Only the hash is written down: a leaked database must not hand out
	// working sessions.
	var stored string
	if err := st.DB.QueryRow(`SELECT token_sha256 FROM api_sessions`).Scan(&stored); err != nil {
		t.Fatalf("read session: %v", err)
	}
	if stored == token {
		t.Fatal("the session token is stored in plaintext")
	}
	if stored != HashToken(token) {
		t.Error("the stored value is not the token's hash")
	}

	session, err := st.LookupSession(ctx, token)
	if err != nil {
		t.Fatalf("LookupSession: %v", err)
	}
	if session.UserID != "alice" || session.PasskeyID != "CRED-1" {
		t.Errorf("session = %+v, want alice via CRED-1", session)
	}

	if err := st.DeleteSession(ctx, token); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	if _, err := st.LookupSession(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Errorf("a revoked session still resolves: %v", err)
	}

	// Two sessions are never the same string, or logging one device out would
	// log out another.
	one, _, _ := st.CreateSession(ctx, "alice", "CRED-1", "")
	two, _, _ := st.CreateSession(ctx, "alice", "CRED-1", "")
	if one == two {
		t.Error("CreateSession reissued the same token")
	}
}
