// Package wikilink extracts [[WikiLinks]] from node bodies and normalizes
// titles into the title_key used to resolve them.
//
// Link resolution is by normalized title, not by ID: an offline user can link
// to a page that does not exist yet (or exists only on someone else's device),
// and the link starts working the moment that page arrives. Dangling links are
// a feature, not an error.
package wikilink

import (
	"regexp"
	"strings"
)

// linkPattern matches [[Target]] and [[Target|label]].
var linkPattern = regexp.MustCompile(`\[\[([^\[\]|]+)(?:\|[^\[\]]*)?\]\]`)

// NormalizeTitle maps a human title to its title_key: trimmed, inner
// whitespace collapsed, lowercased. "  Spaced   Repetition " and
// "spaced repetition" are the same page.
func NormalizeTitle(title string) string {
	return strings.ToLower(strings.Join(strings.Fields(title), " "))
}

// Parse returns the normalized title_keys referenced by body, in first-seen
// order and without duplicates.
func Parse(body string) []string {
	matches := linkPattern.FindAllStringSubmatch(body, -1)
	keys := make([]string, 0, len(matches))
	seen := make(map[string]bool, len(matches))
	for _, m := range matches {
		key := NormalizeTitle(m[1])
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		keys = append(keys, key)
	}
	return keys
}
