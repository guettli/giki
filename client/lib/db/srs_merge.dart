/// Merges duplicate review schedules into the one row every device agrees on.
library;

import 'package:sqlite3/common.dart';

import 'clock.dart';
import 'ids.dart';

/// Collapses every (card, user) that has more than one live schedule into the
/// name-based row, and returns how many pairs it fixed.
///
/// Duplicates exist because schedules used to get random ids: two devices that
/// both reviewed a new card created two rows, and Last-Write-Wins merges
/// versions of a row, never two rows. A device running an older version can
/// still produce one, so this runs on every start rather than once -- finding
/// none is a single indexed query.
///
/// The newest schedule wins, written under the name-based id; the others are
/// tombstoned. Both writes go through the outbox like any other edit, so every
/// device converges on the same row.
int mergeDuplicateSchedules(CommonDatabase db) {
  final duplicated = db.select(
    'SELECT card_id, user_id FROM srs_state WHERE is_deleted = 0 '
    'GROUP BY card_id, user_id HAVING COUNT(*) > 1',
  );
  if (duplicated.isEmpty) {
    return 0;
  }

  db.execute('BEGIN');
  try {
    for (final pair in duplicated) {
      final cardId = pair['card_id'] as String;
      final userId = pair['user_id'] as String;
      final canonical = srsStateId(cardId, userId);
      final now = nowClock();

      final newest = db.select(
        'SELECT box, interval_days, ease, reps, lapses, due_at, last_reviewed_at, created_at '
        'FROM srs_state WHERE card_id = ? AND user_id = ? AND is_deleted = 0 '
        'ORDER BY updated_at DESC, id LIMIT 1',
        [cardId, userId],
      ).first;

      db.execute(
        'INSERT INTO srs_state (id, card_id, user_id, box, interval_days, ease, '
        '                       reps, lapses, due_at, last_reviewed_at, '
        '                       created_at, updated_at, is_deleted) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) '
        'ON CONFLICT (id) DO UPDATE SET '
        '  box = excluded.box, interval_days = excluded.interval_days, '
        '  ease = excluded.ease, reps = excluded.reps, lapses = excluded.lapses, '
        '  due_at = excluded.due_at, last_reviewed_at = excluded.last_reviewed_at, '
        '  updated_at = excluded.updated_at, is_deleted = 0',
        [
          canonical,
          cardId,
          userId,
          newest['box'],
          newest['interval_days'],
          newest['ease'],
          newest['reps'],
          newest['lapses'],
          newest['due_at'],
          newest['last_reviewed_at'],
          newest['created_at'],
          now,
        ],
      );
      db.execute(
        'UPDATE srs_state SET is_deleted = 1, updated_at = ? '
        'WHERE card_id = ? AND user_id = ? AND id <> ? AND is_deleted = 0',
        [now, cardId, userId, canonical],
      );
    }
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
  return duplicated.length;
}
