import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giki/db/search.dart';
import 'package:giki/wiki/snippet.dart';

void main() {
  test('every word becomes a quoted prefix term', () {
    expect(ftsQuery('spac rep'), '"spac"* "rep"*');
    expect(ftsQuery('  Größe, café!  '), '"Größe"* "café"*');
  });

  test('FTS5 syntax in the input is searched for as text', () {
    // Unquoted, these would be operators, a column filter or a syntax error.
    expect(ftsQuery('title: a AND b'), '"title"* "a"* "AND"* "b"*');
    expect(ftsQuery('"unbalanced'), '"unbalanced"*');
    expect(ftsQuery('NEAR(a b)'), '"NEAR a"* "b"*');
  });

  test("a word the tokenizer splits stays one phrase", () {
    expect(ftsQuery("don't panic"), '"don t"* "panic"*');
  });

  test('nothing to search for', () {
    expect(ftsQuery(''), isNull);
    expect(ftsQuery('  -- !! '), isNull);
  });

  test('matched terms are highlighted, the rest is plain', () {
    final span = highlightSnippet(
      'a ${matchStart}Leitner$matchEnd box and ${matchStart}box$matchEnd',
      ThemeData(),
    );
    final parts = span.children!.cast<TextSpan>();
    expect(parts.map((p) => p.text), ['a ', 'Leitner', ' box and ', 'box']);
    expect(parts[1].style?.fontWeight, FontWeight.bold);
    expect(parts[0].style, isNull);
  });

  test('a snippet with a lone marker still renders its text', () {
    final span = highlightSnippet('cut ${matchStart}off', ThemeData());
    expect(span.toPlainText(), 'cut off');
  });
}
