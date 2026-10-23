package auth

import (
	"errors"
	"net/http"
	"testing"
)

func TestParseTokens(t *testing.T) {
	if _, err := ParseTokens(""); err == nil {
		t.Error("empty spec should fail")
	}
	if _, err := ParseTokens("nocolon"); err == nil {
		t.Error("spec without colon should fail")
	}
	if _, err := ParseTokens("tok:"); err == nil {
		t.Error("spec without user should fail")
	}
}

func TestStaticTokensAuthenticate(t *testing.T) {
	st, err := ParseTokens("s3cret:alice, other:bob")
	if err != nil {
		t.Fatalf("ParseTokens: %v", err)
	}
	for _, tc := range []struct {
		header string
		want   string
	}{
		{"Bearer s3cret", "alice"},
		{"Bearer other", "bob"},
	} {
		r, _ := http.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("Authorization", tc.header)
		id, err := st.Authenticate(r)
		if err != nil {
			t.Fatalf("Authenticate(%q): %v", tc.header, err)
		}
		if id.UserID != tc.want {
			t.Errorf("Authenticate(%q) = %q, want %q", tc.header, id.UserID, tc.want)
		}
	}
	for _, header := range []string{"", "Bearer wrong", "s3cret", "Basic s3cret"} {
		r, _ := http.NewRequest(http.MethodGet, "/", nil)
		if header != "" {
			r.Header.Set("Authorization", header)
		}
		if _, err := st.Authenticate(r); !errors.Is(err, ErrUnauthorized) {
			t.Errorf("Authenticate(%q) error = %v, want ErrUnauthorized", header, err)
		}
	}
}
