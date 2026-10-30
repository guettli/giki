/// The derived `[[WikiLink]]` index, in one place.
///
/// There are two ways a page reaches the local database -- the user saves it,
/// or a delta brings it from another device -- and the index used to be
/// maintained by only the first. Pages that arrived by sync therefore never
/// appeared in anyone's backlinks. Every path that writes a page calls this.
library;

import 'package:sqlite3/common.dart';

import '../wiki/wikilink.dart';

/// Rebuilds the `links` rows whose source is [nodeId], from what is stored for
/// that page right now.
///
/// It reads the stored row instead of taking a body from the caller on
/// purpose: after a delta, the Last-Write-Wins guard may have kept the row that
/// was already there, and indexing the payload would index text that never
/// landed. A deleted page links to nothing.
void reindexLinks(CommonDatabase db, String nodeId) {
  db.execute('DELETE FROM links WHERE source_node_id = ?', [nodeId]);

  final rows =
      db.select('SELECT body, is_deleted FROM nodes WHERE id = ?', [nodeId]);
  if (rows.isEmpty || rows.first['is_deleted'] == 1) {
    return;
  }
  for (final key in parseLinks(rows.first['body'] as String)) {
    db.execute(
      'INSERT INTO links (source_node_id, target_title_key, target_node_id) '
      "VALUES (?, ?, COALESCE((SELECT id FROM nodes WHERE title_key = ? AND is_deleted = 0 LIMIT 1), '')) "
      'ON CONFLICT (source_node_id, target_title_key) DO NOTHING',
      [nodeId, key, key],
    );
  }
}

/// Bump when the index needs rebuilding on existing devices.
///
/// Version 1 is the release in which deltas started maintaining the index:
/// every page that had synced before it was missing from backlinks, and
/// fixing the write path alone would not have repaired them. Version 2 stops
/// counting links that are shown as text: in code, or after a backslash.
const int linkIndexVersion = 2;

/// The sync_meta key recording which version of the index a device has.
const String linkIndexVersionKey = 'link_index_version';

/// Rebuilds the whole link index once per [linkIndexVersion], so a fix to how
/// links are derived reaches pages that were written before it.
///
/// Returns how many pages were reindexed (0 when already current). Cheap for a
/// personal wiki -- one pass over `nodes` -- and it only runs after an upgrade.
int ensureLinkIndex(CommonDatabase db) {
  final rows = db.select(
      'SELECT value FROM sync_meta WHERE key = ?', [linkIndexVersionKey]);
  final current =
      rows.isEmpty ? 0 : int.tryParse(rows.first['value'] as String) ?? 0;
  if (current >= linkIndexVersion) {
    return 0;
  }

  final ids = [
    for (final row in db.select('SELECT id FROM nodes')) row['id'] as String,
  ];
  db.execute('BEGIN');
  try {
    for (final id in ids) {
      reindexLinks(db, id);
    }
    db.execute(
      'INSERT INTO sync_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [linkIndexVersionKey, '$linkIndexVersion'],
    );
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
  return ids.length;
}
