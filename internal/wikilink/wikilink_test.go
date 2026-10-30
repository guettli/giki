package wikilink

import "testing"

// Mirrors normalizeTitle in client/test/wikilink_test.dart: both sides
// compute title_key.
func TestNormalizeTitle(t *testing.T) {
	for in, want := range map[string]string{
		"  Spaced   Repetition ": "spaced repetition",
		"Leitner":                "leitner",
		"":                       "",
		"\tTabbed\nTitle":        "tabbed title",
	} {
		if got := NormalizeTitle(in); got != want {
			t.Errorf("NormalizeTitle(%q) = %q, want %q", in, got, want)
		}
	}
}
