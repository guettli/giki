/// Keeps the flashcards written in a page (`question :: answer` lines) in step
/// with edits to its text.
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

/// Applies an edit of page [nodeId] from [before] to [after] to its cards: a
/// line that was added creates its card, a changed answer updates it, a
/// removed line deletes it. Pass '' as [after] when the page is deleted, and
/// '' as [before] when it is created or restored.
///
/// Only lines the edit touched are acted on. A line that is the same before
/// and after leaves its card alone, whatever state the card is in: an answer
/// fixed on the Study page, or a card deleted there or on another device,
/// stays that way until someone edits that line. Comparing cards with the
/// text instead would undo those changes on every save of the page, with a
/// fresh updated_at that wins Last-Write-Wins everywhere.
///
/// A line's card is found by its id, derived from the page and the question
/// (pageCardId) -- not by its current text, which may have been edited
/// since. A card made by hand on the Study page has a random id and is never
/// touched.
///
/// Runs on local saves only. A page that arrives by sync brings its cards
/// along as rows of their own, written by the device that saved it.
PageCardChanges syncPageCards(
  CommonDatabase db, {
  required String nodeId,
  required String before,
  required String after,
  required String userId,
  required String now,
}) {
  Map<String, CardLine> byId(String body) => {
        for (final card in parseCardLines(body))
          pageCardId(nodeId, cardKey(card.front)): card,
      };
  final old = byId(before);
  final wanted = byId(after);

  var created = 0, updated = 0, deleted = 0;
  for (final MapEntry(key: id, value: card) in wanted.entries) {
    final previous = old[id];
    if (previous == card) {
      continue;
    }
    final existed = db.select(
      'SELECT 1 FROM cards WHERE id = ? AND is_deleted = 0',
      [id],
    ).isNotEmpty;
    db.execute(
      'INSERT INTO cards (id, node_id, front, back, created_at, created_by, '
      '                   updated_at, updated_by, is_deleted) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) '
      'ON CONFLICT (id) DO UPDATE SET '
      '  node_id = excluded.node_id, front = excluded.front, '
      '  back = excluded.back, updated_at = excluded.updated_at, '
      '  updated_by = excluded.updated_by, is_deleted = 0',
      [id, nodeId, card.front, card.back, now, userId, now, userId],
    );
    if (existed) {
      updated++;
    } else {
      created++;
    }
  }
  for (final id in old.keys) {
    if (wanted.containsKey(id)) {
      continue;
    }
    final result = db.select(
      'UPDATE cards SET is_deleted = 1, updated_at = ?, updated_by = ? '
      'WHERE id = ? AND is_deleted = 0 RETURNING id',
      [now, userId, id],
    );
    deleted += result.length;
  }
  return PageCardChanges(created: created, updated: updated, deleted: deleted);
}

/// The line of [body] that writes card [cardId] of page [nodeId], or null
/// when there is none: the card was made by hand, or its line is gone.
CardLineAt? pageCardLine(String body,
    {required String nodeId, required String cardId}) {
  for (final at in cardLinesAt(body)) {
    if (pageCardId(nodeId, cardKey(at.card.front)) == cardId) {
      return at;
    }
  }
  return null;
}

/// [body] with [line] changed to `front :: back`, or removed when [front] is
/// null. Null when the new line would not read back as that card: a question
/// already asked further up the page, or text that does not fit on one card
/// line.
///
/// This is how the Study page edits a card from a page: through its line,
/// which is what the card is derived from. Writing the card row alone would
/// be undone the next time someone edits that line.
String? editPageCardLine(String body, CardLineAt line,
    {String? front, String back = ''}) {
  final lines = body.split('\n');
  if (front == null) {
    lines.removeAt(line.lineIndex);
    return lines.join('\n');
  }
  final ending = lines[line.lineIndex].endsWith('\r') ? '\r' : '';
  lines[line.lineIndex] = '${line.prefix}$front :: $back$ending';
  final edited = lines.join('\n');
  final readBack = [
    for (final at in cardLinesAt(edited))
      if (at.lineIndex == line.lineIndex) at.card,
  ];
  return readBack.length == 1 &&
          readBack.single == CardLine(front.trim(), back.trim())
      ? edited
      : null;
}
