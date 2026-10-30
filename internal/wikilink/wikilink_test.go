package wikilink

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

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

// TestParse runs testdata/cases.json, which client/test_vm/wikilink_test.dart
// runs too: client and server must agree about where a link points.
func TestParse(t *testing.T) {
	data, err := os.ReadFile("testdata/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var tests []struct {
		Name string   `json:"name"`
		Body string   `json:"body"`
		Want []string `json:"want"`
	}
	if err := json.Unmarshal(data, &tests); err != nil {
		t.Fatal(err)
	}
	for _, tc := range tests {
		t.Run(tc.Name, func(t *testing.T) {
			if got := Parse(tc.Body); !reflect.DeepEqual(got, tc.Want) {
				t.Errorf("Parse(%q) = %q, want %q", tc.Body, got, tc.Want)
			}
		})
	}
}
