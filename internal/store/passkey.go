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

// PasskeyUserCount reports how many users have registered a passkey. Used to
// decide whether an instance still needs its bootstrap registration token.
func (s *Store) PasskeyUserCount(ctx context.Context) (int, error) {
	var count int
	if err := s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM passkey_users`).Scan(&count); err != nil {
		return 0, fmt.Errorf("count passkey users: %w", err)
	}
	return count, nil
}

// SavePasskey stores a newly registered credential.
func (s *Store) SavePasskey(ctx context.Context, p Passkey) error {
	_, err := s.DB.ExecContext(ctx, `
		INSERT INTO passkeys (id, user_id, label, credential, created_at, last_used_at)
		VALUES (?, ?, ?, ?, ?, '')
		ON CONFLICT (id) DO UPDATE SET
			user_id    = excluded.user_id,
			label      = excluded.label,
			credential = excluded.credential`,
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

// DeletePasskey removes one credential.
func (s *Store) DeletePasskey(ctx context.Context, id string) error {
	if _, err := s.DB.ExecContext(ctx, `DELETE FROM passkeys WHERE id = ?`, id); err != nil {
		return fmt.Errorf("delete passkey: %w", err)
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
	id, _, err := NewToken()
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	if _, err := s.DB.ExecContext(ctx,
		`DELETE FROM passkey_ceremonies WHERE expires_at < ?`, now.Format(TimeFormat)); err != nil {
		return "", fmt.Errorf("prune ceremonies: %w", err)
	}
	_, err = s.DB.ExecContext(ctx, `
		INSERT INTO passkey_ceremonies (id, kind, user_id, session, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		id, kind, userID, string(session),
		now.Format(TimeFormat), now.Add(CeremonyTTL).Format(TimeFormat))
	if err != nil {
		return "", fmt.Errorf("save ceremony: %w", err)
	}
	return id, nil
}

// TakeCeremony returns a ceremony and deletes it, so a challenge can only be
// answered once -- a replayed response finds nothing to verify against.
func (s *Store) TakeCeremony(ctx context.Context, id, kind string) (userID string, session []byte, err error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit

	var storedKind, storedSession, expires string
	err = tx.QueryRowContext(ctx,
		`SELECT kind, user_id, session, expires_at FROM passkey_ceremonies WHERE id = ?`, id).
		Scan(&storedKind, &userID, &storedSession, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, ErrNotFound
	}
	if err != nil {
		return "", nil, fmt.Errorf("read ceremony: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM passkey_ceremonies WHERE id = ?`, id); err != nil {
		return "", nil, fmt.Errorf("consume ceremony: %w", err)
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
	if _, err := s.DB.ExecContext(ctx,
		`UPDATE api_sessions SET last_seen_at = ? WHERE token_sha256 = ?`, now, hash); err != nil {
		return Session{}, fmt.Errorf("touch session: %w", err)
	}
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

// DeleteSessionsOfPasskey revokes every session that a given credential
// created. Removing a lost authenticator has to log out the devices it signed
// in, or the removal is theatre.
func (s *Store) DeleteSessionsOfPasskey(ctx context.Context, passkeyID string) error {
	if _, err := s.DB.ExecContext(ctx,
		`DELETE FROM api_sessions WHERE passkey_id = ?`, passkeyID); err != nil {
		return fmt.Errorf("delete sessions of passkey: %w", err)
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
	var existing string
	err := s.DB.QueryRowContext(ctx, `SELECT id FROM users WHERE id = ?`, userID).Scan(&existing)
	switch {
	case err == nil:
		return nil
	case !errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("read user %s: %w", userID, err)
	}

	now := Now()
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
	if results[0].Status == StatusRejected {
		return fmt.Errorf("could not create user %s: %s", userID, results[0].Reason)
	}
	return nil
}
