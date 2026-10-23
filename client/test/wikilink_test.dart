import 'package:flutter_test/flutter_test.dart';
import 'package:giki/wiki/wikilink.dart';

void main() {
  test('normalizes titles', () {
    expect(normalizeTitle('  Spaced   Repetition '), 'spaced repetition');
    expect(normalizeTitle('Leitner'), 'leitner');
    expect(normalizeTitle(''), '');
    expect(normalizeTitle('\tTabbed\nTitle'), 'tabbed title');
  });

  // Mirrors TestParse in internal/wikilink/wikilink_test.go. If one side
  // changes, the other must too, or client and server will disagree about
  // where a link points.
  test('parses links', () {
    expect(parseLinks('plain text'), isEmpty);
    expect(parseLinks('see [[Leitner]] and [[SM-2]]'), ['leitner', 'sm-2']);
    expect(parseLinks('see [[Spaced Repetition|the method]]'), ['spaced repetition']);
    expect(parseLinks('[[A]] then [[a]] again'), ['a']);
    expect(parseLinks('[[broken and [[Good]]'), ['good']);
    expect(parseLinks('[[]] [[ ]] [[Real]]'), ['real']);
  });
}
