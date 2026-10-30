// Package wikilink extracts [[WikiLinks]] from node bodies and normalizes
// titles into the title_key used to resolve them.
//
// Link resolution is by normalized title, not by ID: an offline user can link
// to a page that does not exist yet (or exists only on someone else's device),
// and the link starts working the moment that page arrives. Dangling links are
// a feature, not an error.
//
// Only links that the client renders as links count: a [[link]] in a code
// block, in a `code span` or after a backslash is shown as text, so it must
// not show up in backlinks either. The cases both sides agree on are in
// testdata/cases.json, which the client's tests read too.
package wikilink

import (
	"regexp"
	"strings"
)

// linkPattern matches [[Target]] and [[Target|label]] at the start of the
// text it is given.
var linkPattern = regexp.MustCompile(`^\[\[([^\[\]|]+)(?:\|[^\[\]]*)?\]\]`)

var (
	// fencePattern matches a code fence, also one inside a quote or a list
	// item: "> ```" and "1. ```" open code blocks too.
	fencePattern    = regexp.MustCompile("^(?:[ \t]*(?:>|(?:[-*+]|\\d{1,9}[.)])(?:[ \t]|$)))*[ \t]*(`{3,}|~{3,})(.*)$")
	listItemPattern = regexp.MustCompile(`^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)`)
	// blockStartPattern matches lines that start a new block, and with it a
	// new run of inline text: headings, quotes, list items, table rows.
	blockStartPattern = regexp.MustCompile(`^ {0,3}(?:#{1,6}(?:[ \t]|$)|>|[-*+][ \t]|\d{1,9}[.)][ \t]|\|)`)
	lineEnding        = regexp.MustCompile(`\r\n?`)
)

// NormalizeTitle maps a human title to its title_key: trimmed, inner
// whitespace collapsed, lowercased. "  Spaced   Repetition " and
// "spaced repetition" are the same page.
func NormalizeTitle(title string) string {
	return strings.ToLower(strings.Join(strings.Fields(title), " "))
}

// Parse returns the normalized title_keys referenced by body, in first-seen
// order and without duplicates.
func Parse(body string) []string {
	keys := []string{}
	seen := map[string]bool{}
	for _, text := range inlineTexts(body) {
		for _, target := range scanInline(text) {
			key := NormalizeTitle(target)
			if key == "" || seen[key] {
				continue
			}
			seen[key] = true
			keys = append(keys, key)
		}
	}
	return keys
}

// inlineTexts splits body into the runs of text that Markdown parses for
// inline syntax, leaving out fenced and indented code blocks.
func inlineTexts(body string) []string {
	var texts, run []string
	flush := func() {
		if len(run) > 0 {
			texts = append(texts, strings.Join(run, "\n"))
			run = nil
		}
	}
	fence := ""
	inList := false   // the last block that started at the margin is a list item
	prevBlank := true // the previous line was blank, or there was none
	prevIndented := false
	for _, line := range strings.Split(lineEnding.ReplaceAllString(body, "\n"), "\n") {
		if fence != "" {
			// CommonMark: the closing fence uses the same character, is at
			// least as long as the opening one, and has no info string.
			if m := fencePattern.FindStringSubmatch(line); m != nil &&
				strings.HasPrefix(m[1], fence) && strings.TrimSpace(m[2]) == "" {
				fence = ""
			}
			continue
		}
		if strings.TrimSpace(line) == "" {
			flush()
			prevBlank = true
			continue
		}
		indented := indent(line) >= 4
		if indented && !inList && (prevBlank || prevIndented) {
			flush() // an indented code block
			prevBlank, prevIndented = false, true
			continue
		}
		prevBlank, prevIndented = false, false
		if m := fencePattern.FindStringSubmatch(line); m != nil &&
			!(m[1][0] == '`' && strings.Contains(m[2], "`")) {
			flush()
			fence = m[1]
			continue
		}
		if !indented {
			inList = listItemPattern.MatchString(line)
		}
		if blockStartPattern.MatchString(line) {
			flush()
		}
		run = append(run, line)
	}
	flush()
	return texts
}

// indent is the width of line's leading whitespace, a tab counting as four.
func indent(line string) int {
	width := 0
	for _, c := range line {
		switch c {
		case ' ':
			width++
		case '\t':
			width += 4 - width%4
		default:
			return width
		}
	}
	return width
}

// scanInline returns the targets of the [[links]] in text, reading it left
// to right the way the Markdown inline parser does: a backslash escapes the
// next punctuation character, a code span hides everything inside it, and the
// "![" that opens an image takes the bracket, so ![[Page]] is no link.
func scanInline(text string) []string {
	var targets []string
	for i := 0; i < len(text); {
		switch {
		case text[i] == '\\' && i+1 < len(text) && isASCIIPunct(text[i+1]):
			i += 2
		case strings.HasPrefix(text[i:], "!["):
			i += 2
		case text[i] == '`':
			i = skipCodeSpan(text, i)
		case strings.HasPrefix(text[i:], "[["):
			if m := linkPattern.FindStringSubmatchIndex(text[i:]); m != nil {
				targets = append(targets, text[i+m[2]:i+m[3]])
				i += m[1]
			} else {
				i++
			}
		default:
			i++
		}
	}
	return targets
}

// skipCodeSpan returns where scanning continues after the backtick run at
// start: past the closing run of the same length, or past the opening run
// when there is none and the backticks are literal.
func skipCodeSpan(text string, start int) int {
	open := runLength(text, start)
	for i := start + open; i < len(text); {
		if text[i] != '`' {
			i++
			continue
		}
		n := runLength(text, i)
		if n == open {
			return i + n
		}
		i += n
	}
	return start + open
}

func runLength(text string, start int) int {
	n := 0
	for start+n < len(text) && text[start+n] == '`' {
		n++
	}
	return n
}

func isASCIIPunct(c byte) bool {
	return strings.IndexByte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) >= 0
}
