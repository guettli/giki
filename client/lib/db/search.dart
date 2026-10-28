/// Full-text search over the local pages, backed by the `nodes_fts` index in
/// db/schema_client.sql.
library;

import 'package:sqlite3/common.dart';

/// Bump when the index needs rebuilding on existing devices.
///
/// Version 1 is the release that introduced the index: its triggers only see
/// writes made after it, so every page a device already had needs indexing.
const int searchIndexVersion = 1;

/// The sync_meta key recording which version of the index a device has.
const String searchIndexVersionKey = 'search_index_version';

/// Marks the start of a matched term in [SearchHit.snippet].
const String matchStart = '';

/// Marks the end of a matched term in [SearchHit.snippet].
const String matchEnd = '';

/// One page that matches a search.
class SearchHit {
  const SearchHit({
    required this.id,
    required this.title,
    required this.snippet,
  });

  final String id;
  final String title;

  /// A short excerpt of the body around the match -- or its start, when only
  /// the title matched -- with every matched term wrapped in
  /// [matchStart] and [matchEnd]. Private-use characters rather than markup,
  /// so a page that contains brackets or tags cannot fake a highlight.
  final String snippet;
}

/// Rebuilds the search index once per [searchIndexVersion].
///
/// Returns true when it rebuilt. One pass over `nodes`, and only after an
/// upgrade; every later start is a single indexed lookup.
bool ensureSearchIndex(CommonDatabase db) {
  final rows = db.select(
      'SELECT value FROM sync_meta WHERE key = ?', [searchIndexVersionKey]);
  final current =
      rows.isEmpty ? 0 : int.tryParse(rows.first['value'] as String) ?? 0;
  if (current >= searchIndexVersion) {
    return false;
  }
  db.execute('BEGIN');
  try {
    db.execute("INSERT INTO nodes_fts (nodes_fts) VALUES ('rebuild')");
    db.execute(
      'INSERT INTO sync_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [searchIndexVersionKey, '$searchIndexVersion'],
    );
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
  return true;
}

/// Turns what the user typed into an FTS5 query, or null when there is
/// nothing to search for.
///
/// Every word becomes a quoted prefix phrase, and all of them must match:
/// typing "spac rep" finds "Spaced Repetition". Quoting means FTS5 syntax in
/// the input -- AND, NEAR, a stray quote or a column filter -- is searched for
/// as text instead of failing with a syntax error. A word the tokenizer splits,
/// like "don't", stays one phrase ("don t"), rather than a bare "t" prefix that
/// would match nearly every page.
String? ftsQuery(String input) {
  final phrases = <String>[];
  for (final word in input.split(RegExp(r'\s+'))) {
    final tokens = word
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((token) => token.isNotEmpty);
    if (tokens.isNotEmpty) {
      // Tokens hold only letters and digits, so no quote needs escaping.
      phrases.add('"${tokens.join(' ')}"*');
    }
  }
  return phrases.isEmpty ? null : phrases.join(' ');
}

/// Finds live pages matching [input], best match first. A match in the title
/// counts for more than one in the body.
List<SearchHit> searchNodes(CommonDatabase db, String input, {int limit = 50}) {
  final query = ftsQuery(input);
  if (query == null) {
    return const [];
  }
  final rows = db.select(
    'SELECT n.id, n.title, '
    // Always the body: a title-only match would otherwise repeat the title as
    // its own snippet and show nothing of the page.
    "snippet(nodes_fts, 1, '$matchStart', '$matchEnd', '…', 12) AS snippet "
    'FROM nodes_fts JOIN nodes n ON n.rowid = nodes_fts.rowid '
    'WHERE nodes_fts MATCH ? AND n.is_deleted = 0 '
    'ORDER BY bm25(nodes_fts, 5.0, 1.0) '
    'LIMIT ?',
    [query, limit],
  );
  return [
    for (final row in rows)
      SearchHit(
        id: row['id'] as String,
        title: row['title'] as String,
        snippet: row['snippet'] as String,
      ),
  ];
}
