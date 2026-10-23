package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// ErrNotFound is returned when a passkey, ceremony or session does not exist
// (or has expired, which for the caller is the same thing).
var ErrNotFound = errors.New("not found")

// SessionTTL is how long a bearer session issued by a passkey ceremony lasts.
//
// Long, deliberately: giki is local-first, so a user whose session expired can
// still read and write everything offline -- only sync stops. Being logged out
// every week would be a lot of friction for no security gain on a device that
// already holds the whole knowledge base.
const SessionTTL = 30 * 24 * time.Hour

// CeremonyTTL bounds how long a half-finished WebAuthn ceremony stays valid.
const CeremonyTTL = 5 * time.Minute

// PasskeyUser is the WebAuthn view of a user: the handle an authenticator
// stores, which is deliberately not the app-level user id.
type PasskeyUser struct {
	UserID      string
	Handle      []byte
	DisplayName string
}

// Passkey is one registered authenticator.
type Passkey struct {
	ID         string // base64url credential ID
	UserID     string
	Label      string
	Credential []byte // webauthn.Credential as JSON
	CreatedAt  string
	LastUsedAt string
}

// NewToken returns a 32-byte random token, base64url encoded, and its storage
// hash. Only the hash is ever written down.
func NewToken() (token, hash string, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", "", fmt.Errorf("generate token: %w", err)
	}
	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, HashToken(token), nil
}

// HashToken is the one-way function under api_sessions.token_sha256.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// EnsurePasskeyUser returns the WebAuthn user for userID, creating it with a
// fresh random handle the first time.
func (s *Store) EnsurePasskeyUser(ctx context.Context, userID, displayName string) (PasskeyUser, error) {
	if userID == "" {
		return PasskeyUser{}, errors.New("user id must not be empty")
	}

	var encoded string
	var stored string
	err := s.DB.QueryRowContext(ctx,
		`SELECT handle, display_name FROM passkey_users WHERE user_id = ?`, userID).Scan(&encoded, &stored)
	switch {
	case err == nil:
		handle, decodeErr := base64.RawURLEncoding.DecodeString(encoded)
		if decodeErr != nil {
			return PasskeyUser{}, fmt.Errorf("stored handle for %s is not base64url: %w", userID, decodeErr)
		}
		if displayName != "" && displayName != stored {
			if _, err := s.DB.ExecContext(ctx,
				`UPDATE passkey_users SET display_name = ? WHERE user_id = ?`, displayName, userID); err != nil {
				return PasskeyUser{}, fmt.Errorf("update display name: %w", err)
			}
			stored = displayName
		}
		return PasskeyUser{UserID: userID, Handle: handle, DisplayName: stored}, nil
	case !errors.Is(err, sql.ErrNoRows):
		return PasskeyUser{}, fmt.Errorf("read passkey user: %w", err)
	}

	handle := make([]byte, 32)
	if _, err := rand.Read(handle); err != nil {
		return PasskeyUser{}, fmt.Errorf("generate handle: %w", err)
	}
	if displayName == "" {
		displayName = userID
	}
	_, err = s.DB.ExecContext(ctx,
		`INSERT INTO passkey_users (user_id, handle, display_name, created_at) VALUES (?, ?, ?, ?)`,
		userID, base64.RawURLEncoding.EncodeToString(handle), displayName, Now())
	if err != nil {
		return PasskeyUser{}, fmt.Errorf("create passkey user: %w", err)
	}
	return PasskeyUser{UserID: userID, Handle: handle, DisplayName: displayName}, nil
}

// PasskeyUserByHandle resolves the handle an authenticator returned during a
// discoverable login.
func (s *Store) PasskeyUserByHandle(ctx context.Context, handle []byte) (PasskeyUser, error) {
	encoded := base64.RawURLEncoding.EncodeToString(handle)
	var userID, displayName string
	err := s.DB.QueryRowContext(ctx,
		`SELECT user_id, display_name FROM passkey_users WHERE handle = ?`, encoded).Scan(&userID, &displayName)
	if errors.Is(err, sql.ErrNoRows) {
		return PasskeyUser{}, ErrNotFound
	}
	if err != nil {
		return PasskeyUser{}, fmt.Errorf("read passkey user by handle: %w", err)
	}
	return PasskeyUser{UserID: userID, Handle: handle, DisplayName: displayName}, nil
}

// PasskeyUserExists reports whether userID has ever registered a passkey.
//
// The registration gate needs this: a token that could name an existing
// account would let anyone who was ever invited to sign up attach their own
// authenticator to somebody else's account, and then write as them.
func (s *Store) PasskeyUserExists(ctx context.Context, userID string) (bool, error) {
	var one int
	err := s.DB.QueryRowContext(ctx,
		`SELECT 1 FROM passkey_users WHERE user_id = ?`, userID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("look up passkey user: %w", err)
	}
	return true, nil
}

// ErrCredentialClaimed means the credential ID is already registered to
// another account.
var ErrCredentialClaimed = errors.New("credential already registered to another user")

// SavePasskey stores a newly registered credential.
//
// A credential ID that already belongs to someone else is refused rather than
// reassigned. The ID comes from attested credential data, and with attestation
// conveyance "none" nothing vouches for it, so a caller who can register at
// all could otherwise steal a victim's authenticator row by claiming its ID --
// locking the victim out if it was their only one.
//
// `user_id` is deliberately absent from the conflict update for the same
// reason: re-registering the same authenticator refreshes its key material,
// never its owner.
func (s *Store) SavePasskey(ctx context.Context, p Passkey) error {
	var owner string
	err := s.DB.QueryRowContext(ctx, `SELECT user_id FROM passkeys WHERE id = ?`, p.ID).Scan(&owner)
	switch {
	case err == nil && owner != p.UserID:
		return fmt.Errorf("%w: %s", ErrCredentialClaimed, p.ID)
	case err != nil && !errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("read passkey owner: %w", err)
	}

	_, err = s.DB.ExecContext(ctx, `
		INSERT INTO passkeys (id, user_id, label, credential, created_at, last_used_at)
		VALUES (?, ?, ?, ?, ?, '')
		ON CONFLICT (id) DO UPDATE SET
			label      = excluded.label,
			credential = excluded.credential
		WHERE passkeys.user_id = excluded.user_id`,
		p.ID, p.UserID, p.Label, string(p.Credential), Now())
	if err != nil {
		return fmt.Errorf("save passkey: %w", err)
	}
	return nil
}

// PasskeysByUser lists a user's credentials, oldest first.
func (s *Store) PasskeysByUser(ctx context.Context, userID string) ([]Passkey, error) {
	rows, err := s.DB.QueryContext(ctx, `
		SELECT id, user_id, label, credential, created_at, last_used_at
		FROM passkeys WHERE user_id = ? ORDER BY created_at`, userID)
	if err != nil {
		return nil, fmt.Errorf("list passkeys: %w", err)
	}
	defer rows.Close()

	var passkeys []Passkey
	for rows.Next() {
		var p Passkey
		var credential string
		if err := rows.Scan(&p.ID, &p.UserID, &p.Label, &credential, &p.CreatedAt, &p.LastUsedAt); err != nil {
			return nil, fmt.Errorf("scan passkey: %w", err)
		}
		p.Credential = []byte(credential)
		passkeys = append(passkeys, p)
	}
	return passkeys, rows.Err()
}

// PasskeyByID returns one credential.
func (s *Store) PasskeyByID(ctx context.Context, id string) (Passkey, error) {
	var p Passkey
	var credential string
	err := s.DB.QueryRowContext(ctx, `
		SELECT id, user_id, label, credential, created_at, last_used_at
		FROM passkeys WHERE id = ?`, id).Scan(
		&p.ID, &p.UserID, &p.Label, &credential, &p.CreatedAt, &p.LastUsedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Passkey{}, ErrNotFound
	}
	if err != nil {
		return Passkey{}, fmt.Errorf("read passkey: %w", err)
	}
	p.Credential = []byte(credential)
	return p, nil
}

// TouchPasskey records a successful login and the authenticator's new sign
// count.
//
// The sign count is the authenticator's own counter, and writing it back is
// what makes a cloned credential detectable: a replayed assertion arrives with
// a count that has not moved.
func (s *Store) TouchPasskey(ctx context.Context, id string, credential []byte) error {
	_, err := s.DB.ExecContext(ctx,
		`UPDATE passkeys SET credential = ?, last_used_at = ? WHERE id = ?`,
		string(credential), Now(), id)
	if err != nil {
		return fmt.Errorf("touch passkey: %w", err)
	}
	return nil
}

// ErrLastPasskey means the credential is the account's only one.
var ErrLastPasskey = errors.New("cannot remove the account's last passkey")

// DeletePasskey removes one credential and revokes the sessions it issued,
// refusing to remove an account's last one.
//
// All three in one transaction, for two reasons. The count and the delete must
// not be separate statements: two concurrent removals would each see two
// credentials remaining and both proceed, leaving an account with none and no
// password to fall back on. And a revocation that failed after the delete
// committed would leave the credential gone but its sessions alive -- the
// opposite of what removing an authenticator is for.
func (s *Store) DeletePasskey(ctx context.Context, id, userID string) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit

	// Ownership first. A credential that is not the caller's is "not found",
	// and answering that before the last-passkey rule keeps the two refusals
	// from leaking into each other: otherwise a caller with no passkeys at all
	// would be told "this is your only passkey" about somebody else's.
	var owned int
	err = tx.QueryRowContext(ctx,
		`SELECT 1 FROM passkeys WHERE id = ? AND user_id = ?`, id, userID).Scan(&owned)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("read passkey: %w", err)
	}

	var remaining int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM passkeys WHERE user_id = ?`, userID).Scan(&remaining); err != nil {
		return fmt.Errorf("count passkeys: %w", err)
	}
	if remaining <= 1 {
		return ErrLastPasskey
	}

	result, err := tx.ExecContext(ctx, `DELETE FROM passkeys WHERE id = ? AND user_id = ?`, id, userID)
	if err != nil {
		return fmt.Errorf("delete passkey: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("delete passkey: %w", err)
	}
	if affected == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM api_sessions WHERE passkey_id = ?`, id); err != nil {
		return fmt.Errorf("revoke sessions of passkey: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

// --- ceremonies ------------------------------------------------------------

// SaveCeremony stores the challenge of an in-flight ceremony and returns the
// opaque handle the client sends back.
//
// Expired rows are pruned here rather than by a background job: the table only
// grows when someone starts a ceremony, so that is exactly when it is worth
// tidying.
func (s *Store) SaveCeremony(ctx context.Context, kind, userID string, session []byte) (string, error) {
	if kind != "register" && kind != "login" {
		return "", fmt.Errorf("unknown ceremony kind %q", kind)
	}
	handle, hash, err := NewToken()
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	if _, err := s.DB.ExecContext(ctx,
		`DELETE FROM passkey_ceremonies WHERE expires_at < ?`, now.Format(TimeFormat)); err != nil {
		return "", fmt.Errorf("prune ceremonies: %w", err)
	}
	// The hash, not the handle: /register/finish is unauthenticated and the
	// handle is its only authorization, so a handle read out of the database
	// (or a backup, or a log) would let somebody finish another person's
	// registration with their own authenticator. Same reasoning as
	// api_sessions.
	_, err = s.DB.ExecContext(ctx, `
		INSERT INTO passkey_ceremonies (id, kind, user_id, session, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		hash, kind, userID, string(session),
		now.Format(TimeFormat), now.Add(CeremonyTTL).Format(TimeFormat))
	if err != nil {
		return "", fmt.Errorf("save ceremony: %w", err)
	}
	return handle, nil
}

// TakeCeremony returns a ceremony and deletes it, so a challenge can only be
// answered once -- a replayed response finds nothing to verify against.
func (s *Store) TakeCeremony(ctx context.Context, handle, kind string) (userID string, session []byte, err error) {
	hash := HashToken(handle)

	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit

	var storedKind, storedSession, expires string
	err = tx.QueryRowContext(ctx,
		`SELECT kind, user_id, session, expires_at FROM passkey_ceremonies WHERE id = ?`, hash).
		Scan(&storedKind, &userID, &storedSession, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, ErrNotFound
	}
	if err != nil {
		return "", nil, fmt.Errorf("read ceremony: %w", err)
	}

	// The DELETE, not the SELECT, is what makes a ceremony single-use: only
	// the transaction that actually removed the row may continue. Checking the
	// row count keeps that guarantee here rather than resting on the
	// connection pool's isolation.
	result, err := tx.ExecContext(ctx, `DELETE FROM passkey_ceremonies WHERE id = ?`, hash)
	if err != nil {
		return "", nil, fmt.Errorf("consume ceremony: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return "", nil, fmt.Errorf("consume ceremony: %w", err)
	}
	if affected != 1 {
		return "", nil, ErrNotFound
	}
	if err := tx.Commit(); err != nil {
		return "", nil, fmt.Errorf("commit: %w", err)
	}

	if storedKind != kind {
		// A register response must not finish a login ceremony or the other
		// way round.
		return "", nil, ErrNotFound
	}
	if expires < Now() {
		return "", nil, ErrNotFound
	}
	return userID, []byte(storedSession), nil
}

// --- sessions --------------------------------------------------------------

// Session is an issued bearer session.
type Session struct {
	UserID    string
	PasskeyID string
	Label     string
	ExpiresAt string
}

// CreateSession issues a bearer token for userID and returns it. The token is
// returned once and never stored, only its hash.
func (s *Store) CreateSession(ctx context.Context, userID, passkeyID, label string) (token string, expiresAt string, err error) {
	token, hash, err := NewToken()
	if err != nil {
		return "", "", err
	}
	now := time.Now().UTC()
	expiresAt = now.Add(SessionTTL).Format(TimeFormat)
	// Sessions are otherwise only pruned when their own token is presented
	// again, so an abandoned one would sit in the table forever.
	if _, err := s.DB.ExecContext(ctx,
		`DELETE FROM api_sessions WHERE expires_at < ?`, now.Format(TimeFormat)); err != nil {
		return "", "", fmt.Errorf("prune sessions: %w", err)
	}
	_, err = s.DB.ExecContext(ctx, `
		INSERT INTO api_sessions (token_sha256, user_id, passkey_id, label, created_at, last_seen_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		hash, userID, passkeyID, label, now.Format(TimeFormat), now.Format(TimeFormat), expiresAt)
	if err != nil {
		return "", "", fmt.Errorf("create session: %w", err)
	}
	return token, expiresAt, nil
}

// LookupSession resolves a bearer token, or returns ErrNotFound if it is
// unknown or expired. It also records that the session was used.
func (s *Store) LookupSession(ctx context.Context, token string) (Session, error) {
	hash := HashToken(token)
	var session Session
	err := s.DB.QueryRowContext(ctx,
		`SELECT user_id, passkey_id, label, expires_at FROM api_sessions WHERE token_sha256 = ?`, hash).
		Scan(&session.UserID, &session.PasskeyID, &session.Label, &session.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Session{}, ErrNotFound
	}
	if err != nil {
		return Session{}, fmt.Errorf("read session: %w", err)
	}

	now := Now()
	if session.ExpiresAt < now {
		// Clean it up on the way past: an expired session is dead weight, and
		// deleting it here keeps the table bounded without a cron job.
		if _, err := s.DB.ExecContext(ctx, `DELETE FROM api_sessions WHERE token_sha256 = ?`, hash); err != nil {
			return Session{}, fmt.Errorf("delete expired session: %w", err)
		}
		return Session{}, ErrNotFound
	}
	// last_seen_at is diagnostics. A failure here (a locked database, a
	// read-only filesystem) must not turn a valid session into a failed
	// request -- and because the authenticator chain treats a non-auth error
	// as fatal, it would also stop any other credential from being tried.
	_, _ = s.DB.ExecContext(ctx,
		`UPDATE api_sessions SET last_seen_at = ? WHERE token_sha256 = ?`, now, hash)
	return session, nil
}

// DeleteSession revokes one session by its token.
func (s *Store) DeleteSession(ctx context.Context, token string) error {
	if _, err := s.DB.ExecContext(ctx,
		`DELETE FROM api_sessions WHERE token_sha256 = ?`, HashToken(token)); err != nil {
		return fmt.Errorf("delete session: %w", err)
	}
	return nil
}

// EnsureSyncedUser creates the app-level `users` row for a newly registered
// account, so every client learns the display name through the ordinary delta
// feed.
//
// It never overwrites an existing row: registering a second passkey must not
// undo a display name the user has since changed in the app.
func (s *Store) EnsureSyncedUser(ctx context.Context, userID, displayName string) error {
	// A live row is left exactly as it is: registering a second passkey must
	// not undo a display name the user has since changed in the app.
	var storedClock string
	var deleted int
	err := s.DB.QueryRowContext(ctx,
		`SELECT updated_at, is_deleted FROM users WHERE id = ?`, userID).Scan(&storedClock, &deleted)
	switch {
	case err == nil && deleted == 0:
		return nil
	case err != nil && !errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("read user %s: %w", userID, err)
	}

	// A user who was deleted in the app and registers again must come back,
	// or they could authenticate and write while being a nameless tombstone in
	// everybody's copy of the knowledge base.
	//
	// The clock has to beat the tombstone's, and "now" is not guaranteed to:
	// Last-Write-Wins keeps the stored row on an equal timestamp, and a
	// deletion that happened in the same millisecond would silently win.
	now := afterClock(storedClock)
	payload, err := json.Marshal(map[string]any{
		"id":           userID,
		"display_name": displayName,
		"email":        "",
		"created_at":   now,
		"updated_at":   now,
		"is_deleted":   0,
	})
	if err != nil {
		return fmt.Errorf("encode user: %w", err)
	}

	// Through ApplyBatch rather than a direct INSERT, so the row lands in the
	// ChangeLog and reaches every client as a delta. "server" as the device id
	// means no real device is excluded from receiving it.
	results, err := s.ApplyBatch(ctx, Actor{UserID: userID, DeviceID: "server"}, []Mutation{{
		Table:     "users",
		RecordID:  userID,
		Op:        "INSERT",
		UpdatedAt: now,
		Payload:   payload,
	}})
	if err != nil {
		return err
	}
	// Stale as well as rejected: both mean the row the clients will see is not
	// the one this function promised to write, and silence would make the
	// promise untrue in exactly the case it exists for.
	if status := results[0].Status; status != StatusApplied {
		return fmt.Errorf("could not write user %s: %s (%s)", userID, status, results[0].Reason)
	}
	return nil
}

// afterClock returns a timestamp strictly later than stored, and never earlier
// than now. An empty stored clock just gives now.
func afterClock(stored string) string {
	now := Now()
	if stored == "" || stored < now {
		return now
	}
	parsed, err := time.Parse(TimeFormat, stored)
	if err != nil {
		// An unparseable stored clock cannot be reasoned about; now is the
		// best available answer, and LWW will decide.
		return now
	}
	return parsed.Add(time.Millisecond).Format(TimeFormat)
}
