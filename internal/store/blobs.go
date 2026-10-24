package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
)

// Attachment bytes are content-addressed: a blob's key is the SHA-256 of its
// bytes, so a blob is immutable, an upload can be verified without trusting
// the client, and uploading the same file twice stores it once.

// ErrBlobNotFound means no blob with that hash has been uploaded.
var ErrBlobNotFound = errors.New("blob not found")

// ErrBlobMismatch means the uploaded bytes do not hash to the key they were
// uploaded under.
var ErrBlobMismatch = errors.New("blob bytes do not match their sha256")

var blobKey = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ValidBlobKey reports whether key looks like a lowercase hex SHA-256.
func ValidBlobKey(key string) bool { return blobKey.MatchString(key) }

// PutBlob stores data under key, after checking that key is its SHA-256.
// Storing a blob that already exists is a no-op.
func (s *Store) PutBlob(ctx context.Context, key string, data []byte, userID string) error {
	if !ValidBlobKey(key) {
		return fmt.Errorf("%w: %q is not a lowercase hex sha256", ErrRejected, key)
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != key {
		return ErrBlobMismatch
	}
	_, err := s.DB.ExecContext(ctx, `
		INSERT INTO blobs (sha256, size, data, created_by, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (sha256) DO NOTHING`,
		key, len(data), data, userID, Now())
	if err != nil {
		return fmt.Errorf("store blob %s: %w", key, err)
	}
	return nil
}

// Blob returns the bytes stored under key.
func (s *Store) Blob(ctx context.Context, key string) ([]byte, error) {
	var data []byte
	err := s.DB.QueryRowContext(ctx, `SELECT data FROM blobs WHERE sha256 = ?`, key).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrBlobNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("read blob %s: %w", key, err)
	}
	return data, nil
}
