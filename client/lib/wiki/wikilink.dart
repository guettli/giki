/// [[WikiLink]] parsing, mirroring internal/wikilink in the Go server.
///
/// The two implementations must agree, because the client derives its link
/// index offline and the server derives the same index when a node arrives
/// over sync. Both sides run the same table of cases: see
/// test/wikilink_test.dart here and TestParse in
/// internal/wikilink/wikilink_test.go on the server.
library;

final RegExp _linkPattern = RegExp(r'\[\[([^\[\]|]+)(?:\|[^\[\]]*)?\]\]');

/// Maps a human title to its title_key: trimmed, inner whitespace collapsed,
/// lowercased.
String normalizeTitle(String title) =>
    title.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).join(' ').toLowerCase();

/// Returns the normalized title_keys referenced by [body], in first-seen order
/// and without duplicates.
List<String> parseLinks(String body) {
  final keys = <String>[];
  final seen = <String>{};
  for (final match in _linkPattern.allMatches(body)) {
    final key = normalizeTitle(match.group(1)!);
    if (key.isEmpty || !seen.add(key)) {
      continue;
    }
    keys.add(key);
  }
  return keys;
}
