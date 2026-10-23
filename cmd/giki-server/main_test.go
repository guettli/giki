package main

import (
	"io"
	"log/slog"
	"path/filepath"
	"slices"
	"testing"

	"github.com/guettli/giki/internal/store"
)

func TestParseOrigins(t *testing.T) {
	good := map[string][]string{
		"":                         nil,
		"  ,  ":                    nil,
		"http://localhost:8081":    {"http://localhost:8081"},
		"https://giki.example.org": {"https://giki.example.org"},
		"http://a:1, http://b:2":   {"http://a:1", "http://b:2"},
	}
	for spec, want := range good {
		got, err := parseOrigins(spec)
		if err != nil {
			t.Errorf("parseOrigins(%q): %v", spec, err)
			continue
		}
		if !slices.Equal(got, want) {
			t.Errorf("parseOrigins(%q) = %v, want %v", spec, got, want)
		}
	}

	// Each of these would otherwise be accepted at startup and then never
	// match an Origin header, which looks like a broken server rather than a
	// typo in a flag.
	for _, spec := range []string{
		"*",
		"http://a:1,*",
		"giki.example.org",
		"http://localhost:8081/",
	} {
		if _, err := parseOrigins(spec); err == nil {
			t.Errorf("parseOrigins(%q) was accepted", spec)
		}
	}
}

func TestBuildPasskeys(t *testing.T) {
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	defer st.Close()

	// Without a domain there are no passkeys, and that is not an error: a
	// local-only instance is a legitimate configuration.
	service, err := buildPasskeys("", "", st, quiet)
	if err != nil || service != nil {
		t.Errorf("buildPasskeys with no domain = %v, %v; want nil, nil", service, err)
	}

	// The origin defaults to https://<domain>, which is right for every
	// deployment that is not a development box.
	service, err = buildPasskeys("giki.example.org", "", st, quiet)
	if err != nil || service == nil {
		t.Fatalf("buildPasskeys = %v, %v; want a service", service, err)
	}

	// A domain with a scheme or a port is the mistake worth catching at
	// startup: the browser compares the RP ID to the page's host, so a wrong
	// one fails in the authenticator with nothing in the server log.
	for _, domain := range []string{"https://giki.example.org", "giki.example.org:8080"} {
		if _, err := buildPasskeys(domain, "", st, quiet); err == nil {
			t.Errorf("buildPasskeys(%q) was accepted", domain)
		}
	}
}

func TestBuildAuth(t *testing.T) {
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	st, err := store.Open(filepath.Join(t.TempDir(), "giki.sqlite"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	defer st.Close()

	// Each credential type on its own is enough to run the server.
	for _, params := range []struct {
		name     string
		tokens   string
		devUser  string
		passkeys bool
	}{
		{"tokens only", "tok:alice", "", false},
		{"passkeys only", "", "", true},
		{"dev user only", "", "alice", false},
		{"tokens and passkeys", "tok:alice", "", true},
	} {
		if _, err := buildAuth(st, params.tokens, params.devUser, params.passkeys, quiet); err != nil {
			t.Errorf("buildAuth(%s): %v", params.name, err)
		}
	}

	// Nothing configured must fail loudly rather than serve an API that
	// anybody can write to.
	if _, err := buildAuth(st, "", "", false, quiet); err == nil {
		t.Error("buildAuth with no authentication at all was accepted")
	}
	// A static token list and the insecure dev bypass together are a
	// configuration mistake.
	if _, err := buildAuth(st, "tok:alice", "alice", false, quiet); err == nil {
		t.Error("buildAuth accepted -tokens together with -dev-user")
	}
	// A malformed token list is a startup failure, not a silently empty chain.
	if _, err := buildAuth(st, "not-a-pair", "", false, quiet); err == nil {
		t.Error("buildAuth accepted a malformed token list")
	}
}
