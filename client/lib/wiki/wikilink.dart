/// Which pages a page links to.
///
/// The links are read from the same Markdown parse that renders the page
/// (lib/wiki/markdown_parse.dart), so backlinks list exactly the pages that
/// show a link: a [[link]] in code, in an HTML comment or after a backslash
/// is shown as text, and is no backlink either. The server does not derive
/// links; it only computes title_key, with internal/wikilink.NormalizeTitle.
library;

import 'package:markdown/markdown.dart' as md;

import 'markdown_parse.dart';

/// Maps a human title to its title_key: trimmed, inner whitespace collapsed,
/// lowercased. Must match NormalizeTitle in internal/wikilink on the server.
String normalizeTitle(String title) => title
    .trim()
    .split(RegExp(r'\s+'))
    .where((p) => p.isNotEmpty)
    .join(' ')
    .toLowerCase();

/// Returns the normalized title_keys of the `[[links]]` that [body] shows, in
/// first-seen order and without duplicates.
List<String> parseLinks(String body) =>
    [for (final target in linkTargets(body)) normalizeTitle(target)];

/// The targets of the `[[links]]` that [body] shows, as written, in
/// first-seen order and one per title_key.
List<String> linkTargets(String body) {
  final targets = <String>[];
  final seen = <String>{};
  void walk(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is! md.Element) {
        continue;
      }
      final target =
          node.tag == 'a' ? wikiLinkTarget(node.attributes['href']) : null;
      if (target != null) {
        final key = normalizeTitle(target);
        if (key.isNotEmpty && seen.add(key)) {
          targets.add(target.trim());
        }
      }
      walk(node.children ?? const []);
    }
  }

  // A page the parser cannot take is shown as plain text, without links.
  walk(parseRenderable(body)?.nodes ?? const []);
  return targets;
}
