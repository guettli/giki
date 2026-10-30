import 'package:flutter_test/flutter_test.dart';
import 'package:giki/wiki/wikilink.dart';

void main() {
  // Mirrors TestNormalizeTitle in internal/wikilink/wikilink_test.go: both
  // sides compute title_key.
  test('normalizes titles', () {
    expect(normalizeTitle('  Spaced   Repetition '), 'spaced repetition');
    expect(normalizeTitle('Leitner'), 'leitner');
    expect(normalizeTitle(''), '');
    expect(normalizeTitle('\tTabbed\nTitle'), 'tabbed title');
  });

  test('parses links', () {
    expect(parseLinks('plain text'), isEmpty);
    expect(parseLinks('see [[Leitner]] and [[SM-2]]'), ['leitner', 'sm-2']);
    expect(parseLinks('see [[Spaced Repetition|the method]]'),
        ['spaced repetition']);
    expect(parseLinks('[[A]] then [[a]] again'), ['a']);
    expect(parseLinks('[[broken and [[Good]]'), ['good']);
    expect(parseLinks('[[]] [[ ]] [[ |label]] [[Real]]'), ['real']);
  });

  // A backlink promises that the other page shows a link here. These are
  // links that are shown as text, so they are no backlinks.
  final Map<String, String> notLinks = {
    'code span': 'write `[[Hidden]]` to link',
    'fenced code': '```\n[[Hidden]]\n```',
    'indented code': 'text\n\n    [[Hidden]]',
    'escaped bracket': r'\[[Hidden]]',
    'image opener': '![[Hidden]]',
    'HTML comment': '<!-- [[Hidden]] -->',
    'multi-line HTML comment': '<!--\n[[Hidden]]\n-->',
    'fence in a list item': '1. Step:\n   ```\n   [[Hidden]]\n   ```',
    'fence in a quote': '> ```\n> [[Hidden]]\n> ```',
    'inside a URL': '<https://example.org/[[Hidden]]>',
  };
  for (final MapEntry(key: name, value: body) in notLinks.entries) {
    test('no backlink from $name', () {
      expect(parseLinks('$body\n\nbut [[Shown]]'), ['shown']);
    });
  }

  // And links the old line-by-line parser lost although they are shown.
  final Map<String, String> links = {
    'unclosed fence in a quote': '> ```\n> code\n\n[[Shown]]',
    'unclosed fence in a list item': '- ```\n  code\n- [[Shown]]',
    'list item continuation': '1. Step\n\n   Details\n\n    See [[Shown]]',
    'setext heading': 'a `x\n---\n[[Shown]] `',
    'table cell': '| a | b |\n|---|---|\n| `x | [[Shown]] ` |',
    'heading': '# About [[Shown]]',
  };
  for (final MapEntry(key: name, value: body) in links.entries) {
    test('a backlink from $name', () {
      expect(parseLinks(body), ['shown']);
    });
  }

  test('a page the parser cannot take has no links, as it shows none', () {
    // Shown as plain text: see renderableMarkdown.
    expect(parseLinks('[[Plain]]\n\n[a]: <'), isEmpty);
  });

  test('a page the parser takes only after the workaround keeps its links', () {
    expect(parseLinks('[[Shown]]\n\n[C:\\Temp\\'), ['shown']);
  });
}
