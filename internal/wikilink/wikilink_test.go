package wikilink

import (
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

func TestParse(t *testing.T) {
	tests := []struct {
		name string
		body string
		want []string
	}{
		{"none", "plain text", []string{}},
		{"simple", "see [[Leitner]] and [[SM-2]]", []string{"leitner", "sm-2"}},
		{"labelled", "see [[Spaced Repetition|the method]]", []string{"spaced repetition"}},
		{"deduped", "[[A]] then [[a]] again", []string{"a"}},
		{"unclosed", "[[broken and [[Good]]", []string{"good"}},
		{"empty target", "[[]] [[ ]] [[Real]]", []string{"real"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Parse(tc.body); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("Parse(%q) = %v, want %v", tc.body, got, tc.want)
			}
		})
	}
}
