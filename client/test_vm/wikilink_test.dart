// Runs on the VM only: it reads the cases it shares with the Go server from
// disk, which a test running in the browser cannot.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:giki/wiki/markdown_view.dart';
import 'package:giki/wiki/wikilink.dart';
import 'package:markdown/markdown.dart' as md;

/// The normalized targets of the wiki links that PageMarkdown renders for
/// [body], parsed exactly as PageMarkdown parses it.
List<String> renderedLinks(String body) {
  final keys = <String>[];
  void walk(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is md.Element) {
        final target = wikiLinkTarget(node.attributes['href']);
        if (node.tag == 'a' && target != null) {
          final key = normalizeTitle(target);
          if (!keys.contains(key)) {
            keys.add(key);
          }
        }
        walk(node.children ?? const []);
      }
    }
  }

  walk(parsePage(body));
  return keys;
}

void main() {
  final cases = (jsonDecode(File('../internal/wikilink/testdata/cases.json')
          .readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  group('parseLinks agrees with the Go server', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        expect(parseLinks(c['body'] as String), c['want']);
      });
    }
  });

  // Backlinks come from parseLinks, what a reader can tap comes from the
  // Markdown view. A page listed as linking here must show that link.
  group('parseLinks agrees with what the page renders', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        expect(renderedLinks(c['body'] as String), c['want']);
      });
    }
  });
}
