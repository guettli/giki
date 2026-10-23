package main

import (
	"slices"
	"testing"
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
