// Package wikilink normalizes titles into the title_key that [[WikiLinks]]
// resolve by.
//
// Link resolution is by normalized title, not by ID: an offline user can link
// to a page that does not exist yet (or exists only on someone else's device),
// and the link starts working the moment that page arrives. Dangling links are
// a feature, not an error.
//
// Which links a body contains is decided by the client alone, with the same
// Markdown parser that renders the page (client/lib/wiki/wikilink.dart): a
// second parser here could only disagree with it.
package wikilink

import "strings"

// NormalizeTitle maps a human title to its title_key: trimmed, inner
// whitespace collapsed, lowercased. "  Spaced   Repetition " and
// "spaced repetition" are the same page.
func NormalizeTitle(title string) string {
	return strings.ToLower(strings.Join(strings.Fields(title), " "))
}
