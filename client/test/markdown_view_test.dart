import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giki/wiki/markdown_view.dart';
import 'package:markdown/markdown.dart' as md;

String render(String body) =>
    md.markdownToHtml(body, inlineSyntaxes: [WikiLinkSyntax()]);

void main() {
  test('[[links]] become page links; code stays text', () {
    expect(
        render('see [[Spaced Repetition]]'),
        contains(
            '<a href="giki-page:Spaced%20Repetition">Spaced Repetition</a>'));
    expect(render('see [[Leitner|the boxes]]'),
        contains('<a href="giki-page:Leitner">the boxes</a>'));
    expect(render('`[[Not A Link]]`'), isNot(contains('<a')));
  });

  test('a link with no target is text, not a link to an empty page', () {
    expect(render('[[ |label]]'), isNot(contains('<a')));
  });

  test('a malformed escape is no page link', () {
    expect(wikiLinkTarget('giki-page:%FF'), isNull);
  });

  test('a page link round-trips its title', () {
    expect(
        wikiLinkTarget('giki-page:Spaced%20Repetition'), 'Spaced Repetition');
    expect(wikiLinkTarget('https://example.org'), isNull);
    expect(wikiLinkTarget(null), isNull);
  });

  test('only http(s) and mailto links may leave the app', () {
    expect(isSafeExternalLink('https://example.org/x'), isTrue);
    expect(isSafeExternalLink('mailto:a@example.org'), isTrue);
    expect(isSafeExternalLink('javascript:alert(1)'), isFalse);
    expect(isSafeExternalLink('data:text/html,hi'), isFalse);
    expect(isSafeExternalLink('relative/path'), isFalse);
    expect(isSafeExternalLink('https:///nohost'), isFalse);
    expect(isSafeExternalLink(null), isFalse);
  });

  testWidgets('taps reach the right handler; remote images are not fetched',
      (tester) async {
    final wiki = <String>[];
    final external = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PageMarkdown(
          body: 'go to [[Leitner]] or [out](https://example.org) or '
              '[evil](javascript:alert(1))\n\n![tracker](https://example.org/p.png)'
              '\n\n![missing](nowhere.png)',
          imageBytes: (_) => null,
          onWikiLink: wiki.add,
          onExternalLink: external.add,
        ),
      ),
    ));

    await tester.tapOnText(find.textRange.ofSubstring('Leitner'));
    await tester.tapOnText(find.textRange.ofSubstring('out'));
    await tester.tapOnText(find.textRange.ofSubstring('evil'));
    expect(wiki, ['Leitner']);
    expect(external, [Uri.parse('https://example.org')]);

    expect(find.textContaining('Remote image not loaded: tracker'),
        findsOneWidget);
    expect(find.textContaining('Image not available: missing'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('an empty page says how to fill it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PageMarkdown(
        body: '  ',
        imageBytes: (_) => null,
        onWikiLink: (_) {},
        onExternalLink: (_) {},
      ),
    ));
    expect(find.textContaining('This page is empty'), findsOneWidget);
  });

  testWidgets('a malformed image path shows a placeholder, not an error',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PageMarkdown(
          body: 'before\n\n![x](%FF.png)\n\nafter',
          imageBytes: (_) => null,
          onWikiLink: (_) {},
          onExternalLink: (_) {},
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Image not available: x'), findsOneWidget);
    expect(find.textContaining('after'), findsOneWidget);
  });
}
