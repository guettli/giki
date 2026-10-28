/// Keeps the flashcards written in a page (`question :: answer` lines) in step
/// with its text.
library;

import 'package:sqlite3/common.dart';

import '../srs/card_text.dart';
import 'ids.dart';

/// What [syncPageCards] changed.
class PageCardChanges {
  const PageCardChanges({
    required this.created,
    required this.updated,
    required this.deleted,
  });

  final int created;
  final int updated;
  final int deleted;

  bool get isEmpty => created == 0 && updated == 0 && deleted == 0;
}

/// Brings the cards of page [nodeId] in line with [body]: a new line creates a
/// card, a changed answer updates it, a removed line deletes it. With
/// [pageDeleted], every card the page wrote is deleted.
///
/// Only cards the page wrote are touched. They are recognised by their id,
/// which is derived from the page and the question (pageCardId); a card made
/// by hand on the study page has a random id and is left alone, even when it
/// belongs to this page.
///
/// A card is written only when something about it changed. Saving a page
/// stamps the page, not its cards: a fresh updated_at on an unchanged card
/// would win Last-Write-Wins over an edit made to it elsewhere.
///
/// Runs on local saves only. A page that arrives by sync brings its cards
/// along as rows of their own, written by the device that saved it.
PageCardChanges syncPageCards(
  CommonDatabase db, {
  required String nodeId,
  required String body,
  required bool pageDeleted,
  required String userId,
  required String now,
}) {
  final wanted = <String, CardLine>{
    if (!pageDeleted)
      for (final card in parseCardLines(body))
        pageCardId(nodeId, cardKey(card.front)): card,
  };

  final existing = <String, ({String front, String back, bool deleted})>{};
  for (final row in db.select(
    'SELECT id, front, back, is_deleted FROM cards WHERE node_id = ?',
    [nodeId],
  )) {
    final id = row['id'] as String;
    final front = row['front'] as String;
    // Only the page's own cards: the id must be the one this page derives
    // for that question.
    if (id == pageCardId(nodeId, cardKey(front)) || wanted.containsKey(id)) {
      existing[id] = (
        front: front,
        back: row['back'] as String,
        deleted: row['is_deleted'] == 1,
      );
    }
  }

  var created = 0, updated = 0, deleted = 0;
  for (final MapEntry(key: id, value: card) in wanted.entries) {
    final old = existing[id];
    if (old != null &&
        !old.deleted &&
        old.front == card.front &&
        old.back == card.back) {
      continue;
    }
    db.execute(
      'INSERT INTO cards (id, node_id, front, back, created_at, created_by, '
      '                   updated_at, updated_by, is_deleted) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) '
      'ON CONFLICT (id) DO UPDATE SET '
      '  front = excluded.front, back = excluded.back, '
      '  updated_at = excluded.updated_at, updated_by = excluded.updated_by, '
      '  is_deleted = 0',
      [id, nodeId, card.front, card.back, now, userId, now, userId],
    );
    if (old == null || old.deleted) {
      created++;
    } else {
      updated++;
    }
  }
  for (final MapEntry(key: id, value: old) in existing.entries) {
    if (old.deleted || wanted.containsKey(id)) {
      continue;
    }
    db.execute(
      'UPDATE cards SET is_deleted = 1, updated_at = ?, updated_by = ? '
      'WHERE id = ?',
      [now, userId, id],
    );
    deleted++;
  }
  return PageCardChanges(created: created, updated: updated, deleted: deleted);
}
