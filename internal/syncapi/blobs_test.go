package syncapi

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func blobRequest(t *testing.T, ts *httptest.Server, method, key, token string, body []byte) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+"/api/v1/blobs/"+key, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, key, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func hashOf(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func TestBlobRoundTrip(t *testing.T) {
	ts, _ := newTestServer(t)
	data := []byte("\x89PNG\r\n\x1a\n not really a png")
	key := hashOf(data)

	if resp := blobRequest(t, ts, http.MethodPut, key, "alice-token", data); resp.StatusCode != http.StatusOK {
		t.Fatalf("PUT = %d, want 200", resp.StatusCode)
	}
	// Idempotent: the same bytes again are fine.
	if resp := blobRequest(t, ts, http.MethodPut, key, "alice-token", data); resp.StatusCode != http.StatusOK {
		t.Fatalf("second PUT = %d, want 200", resp.StatusCode)
	}

	// Another user reads it: the knowledge base is shared.
	resp := blobRequest(t, ts, http.MethodGet, key, "bob-token", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET = %d, want 200", resp.StatusCode)
	}
	got, _ := io.ReadAll(resp.Body)
	if !bytes.Equal(got, data) {
		t.Fatalf("GET returned %q, want %q", got, data)
	}
	for header, want := range map[string]string{
		"Content-Type":           "application/octet-stream",
		"Content-Disposition":    "attachment",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := resp.Header.Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
}

func TestBlobRejections(t *testing.T) {
	ts, _ := newTestServer(t)
	data := []byte("hello")
	key := hashOf(data)

	cases := []struct {
		name   string
		method string
		key    string
		token  string
		body   []byte
		want   int
	}{
		{"no token", http.MethodPut, key, "", data, http.StatusUnauthorized},
		{"no token on read", http.MethodGet, key, "", nil, http.StatusUnauthorized},
		{"bytes do not match the hash", http.MethodPut, hashOf([]byte("other")), "alice-token", data, http.StatusBadRequest},
		{"not a sha256", http.MethodPut, "abc", "alice-token", data, http.StatusBadRequest},
		{"uppercase hex", http.MethodPut, "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855", "alice-token", nil, http.StatusBadRequest},
		{"too large", http.MethodPut, hashOf(make([]byte, MaxBlobBytes+1)), "alice-token", make([]byte, MaxBlobBytes+1), http.StatusRequestEntityTooLarge},
		{"never uploaded", http.MethodGet, key, "alice-token", nil, http.StatusNotFound},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := blobRequest(t, ts, tc.method, tc.key, tc.token, tc.body).StatusCode; got != tc.want {
				t.Fatalf("status = %d, want %d", got, tc.want)
			}
		})
	}
}

// A mismatched upload must not leave anything behind under the claimed key.
func TestBlobMismatchStoresNothing(t *testing.T) {
	ts, _ := newTestServer(t)
	claimed := hashOf([]byte("the real file"))
	blobRequest(t, ts, http.MethodPut, claimed, "alice-token", []byte("something else"))
	if got := blobRequest(t, ts, http.MethodGet, claimed, "alice-token", nil).StatusCode; got != http.StatusNotFound {
		t.Fatalf("GET after a mismatched PUT = %d, want 404", got)
	}
}
