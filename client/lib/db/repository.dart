/// Domain operations on the local database.
///
/// Every write here is a plain SQLite statement. The outbox triggers turn it
/// into a sync mutation, so no code in this file knows that synchronization
/// exists -- which is the entire point of the Outbox pattern.
library;

import 'dart:convert';

import '../srs/srs.dart';
import '../wiki/wikilink.dart';
import 'clock.dart';
import 'database.dart';
import 'ids.dart';
import 'link_index.dart';

/// A node as shown in lists.
class NodeSummary {
  const NodeSummary(
      {required this.id, required this.title, required this.updatedAt});

  final String id;
  final String title;
  final String updatedAt;
}

/// A full node.
class Node {
  const Node({
    required this.id,
    required this.title,
    required this.titleKey,
    required this.body,
    required this.updatedAt,
    required this.updatedBy,
  });

  final String id;
  final String title;
  final String titleKey;
  final String body;
  final String updatedAt;
  final String updatedBy;
}

/// Reads and writes wiki nodes.
class NodeRepository {
  NodeRepository(this._db);

  final GikiDatabase _db;

  /// All live nodes, most recently edited first.
  List<NodeSummary> recent({int limit = 100}) {
    final rows = _db.raw.select(
      'SELECT id, title, updated_at FROM nodes WHERE is_deleted = 0 '
      'ORDER BY updated_at DESC LIMIT ?',
      [limit],
    );
    return [
      for (final row in rows)
        NodeSummary(
          id: row['id'] as String,
          title: row['title'] as String,
          updatedAt: row['updated_at'] as String,
        ),
    ];
  }

  /// Looks a node up by id.
  Node? byId(String id) {
    final rows = _db.raw.select(
      'SELECT id, title, title_key, body, updated_at, updated_by '
      'FROM nodes WHERE id = ? AND is_deleted = 0',
      [id],
    );
    return rows.isEmpty ? null : _node(rows.first);
  }

  /// Resolves a [[WikiLink]] target.
  Node? byTitle(String title) {
    final rows = _db.raw.select(
      'SELECT id, title, title_key, body, updated_at, updated_by '
      'FROM nodes WHERE title_key = ? AND is_deleted = 0 ORDER BY created_at LIMIT 1',
      [normalizeTitle(title)],
    );
    return rows.isEmpty ? null : _node(rows.first);
  }

  /// Creates a node, or updates the one with [id].
  ///
  /// Returns the node's id, so the caller can navigate to a page that was just
  /// created by following a dangling link.
  String save({String? id, required String title, required String body}) {
    final nodeId = id ?? newId();
    final now = nowClock();
    final titleKey = normalizeTitle(title);
    _db.raw.execute(
      'INSERT INTO nodes (id, title, title_key, body, created_at, created_by, '
      '                   updated_at, updated_by, is_deleted) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) '
      'ON CONFLICT (id) DO UPDATE SET '
      '  title = excluded.title, title_key = excluded.title_key, '
      '  body = excluded.body, updated_at = excluded.updated_at, '
      '  updated_by = excluded.updated_by',
      [nodeId, title, titleKey, body, now, _db.userId, now, _db.userId],
    );
    reindexLinks(_db.raw, nodeId);
    return nodeId;
  }

  /// Tombstones a node. The row stays, so the deletion can be replicated to
  /// devices that are still offline.
  void delete(String id) {
    _db.raw.execute(
      'UPDATE nodes SET is_deleted = 1, updated_at = ?, updated_by = ? WHERE id = ?',
      [nowClock(), _db.userId, id],
    );
    reindexLinks(_db.raw, id);
  }

  /// The nodes that link to [titleKey] -- the passive context that makes a
  /// wiki worth keeping.
  List<NodeSummary> backlinks(String titleKey) {
    final rows = _db.raw.select(
      'SELECT n.id, n.title, n.updated_at FROM links l '
      'JOIN nodes n ON n.id = l.source_node_id '
      'WHERE l.target_title_key = ? AND n.is_deleted = 0 '
      'ORDER BY n.updated_at DESC',
      [titleKey],
    );
    return [
      for (final row in rows)
        NodeSummary(
          id: row['id'] as String,
          title: row['title'] as String,
          updatedAt: row['updated_at'] as String,
        ),
    ];
  }

  Node _node(Map<String, Object?> row) => Node(
        id: row['id'] as String,
        title: row['title'] as String,
        titleKey: row['title_key'] as String,
        body: row['body'] as String,
        updatedAt: row['updated_at'] as String,
        updatedBy: row['updated_by'] as String,
      );
}

/// A flashcard that is due.
class DueCard {
  const DueCard({
    required this.cardId,
    required this.front,
    required this.back,
    required this.state,
  });

  final String cardId;
  final String front;
  final String back;
  final ReviewState state;
}

/// Reads and writes flashcards and their scheduling state.
class CardRepository {
  CardRepository(this._db);

  final GikiDatabase _db;

  /// Creates or updates a flashcard, optionally attached to a node.
  String save(
      {String? id,
      String nodeId = '',
      required String front,
      required String back}) {
    final cardId = id ?? newId();
    final now = nowClock();
    _db.raw.execute(
      'INSERT INTO cards (id, node_id, front, back, created_at, created_by, '
      '                   updated_at, updated_by, is_deleted) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) '
      'ON CONFLICT (id) DO UPDATE SET '
      '  node_id = excluded.node_id, front = excluded.front, back = excluded.back, '
      '  updated_at = excluded.updated_at, updated_by = excluded.updated_by',
      [cardId, nodeId, front, back, now, _db.userId, now, _db.userId],
    );
    return cardId;
  }

  /// The cards due for the current user, soonest first.
  List<DueCard> due({DateTime? at, int limit = 50}) {
    final deadline = formatClock(at ?? DateTime.now());
    final rows = _db.raw.select(
      'SELECT c.id AS card_id, c.front, c.back, '
      '       s.box, s.interval_days, s.reps, s.lapses, s.due_at '
      'FROM cards c '
      // The newest schedule only. Normally there is exactly one per card and
      // user, but a duplicate can still arrive from a device running an older
      // version; joining every row would offer the card once per schedule,
      // and keep offering it after it had been answered.
      'LEFT JOIN srs_state s ON s.id = ('
      '  SELECT id FROM srs_state '
      '  WHERE card_id = c.id AND user_id = ? AND is_deleted = 0 '
      '  ORDER BY updated_at DESC, id LIMIT 1) '
      'WHERE c.is_deleted = 0 AND (s.due_at IS NULL OR s.due_at <= ?) '
      'ORDER BY COALESCE(s.due_at, c.created_at) LIMIT ?',
      [_db.userId, deadline, limit],
    );
    return [
      for (final row in rows)
        DueCard(
          cardId: row['card_id'] as String,
          front: row['front'] as String,
          back: row['back'] as String,
          state: row['due_at'] == null
              ? ReviewState.fresh(at ?? DateTime.now())
              : ReviewState(
                  box: row['box'] as int,
                  intervalDays: row['interval_days'] as int,
                  reps: row['reps'] as int,
                  lapses: row['lapses'] as int,
                  dueAt: parseClock(row['due_at'] as String),
                ),
        ),
    ];
  }

  /// Records a review: updates the schedule and appends to the history.
  ///
  /// Both writes land in one transaction, so the outbox can never contain a
  /// schedule update without the review that caused it.
  void review(DueCard card, Rating rating, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final next = schedule(card.state, rating, now);
    final clock = formatClock(now);

    _db.raw.execute('BEGIN IMMEDIATE');
    try {
      // One srs_state row per (card, user): learning progress is personal,
      // the knowledge base is shared. The id is derived from the pair, not
      // looked up and minted: two devices that both review a new card while
      // offline must create the same row, or Last-Write-Wins has nothing to
      // merge and the card is stuck in the queue for good.
      final stateId = srsStateId(card.cardId, _db.userId);
      _db.raw.execute(
        'INSERT INTO srs_state (id, card_id, user_id, box, interval_days, ease, '
        '                       reps, lapses, due_at, last_reviewed_at, '
        '                       created_at, updated_at, is_deleted) '
        'VALUES (?, ?, ?, ?, ?, 2.5, ?, ?, ?, ?, ?, ?, 0) '
        'ON CONFLICT (id) DO UPDATE SET '
        '  box = excluded.box, interval_days = excluded.interval_days, '
        '  reps = excluded.reps, lapses = excluded.lapses, due_at = excluded.due_at, '
        '  last_reviewed_at = excluded.last_reviewed_at, updated_at = excluded.updated_at',
        [
          stateId,
          card.cardId,
          _db.userId,
          next.box,
          next.intervalDays,
          next.reps,
          next.lapses,
          formatClock(next.dueAt),
          clock,
          clock,
          clock,
        ],
      );
      _db.raw.execute(
        'INSERT INTO review_log (id, card_id, user_id, reviewed_at, rating, '
        '                        prev_box, next_box, created_at, updated_at, is_deleted) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
        [
          newId(),
          card.cardId,
          _db.userId,
          clock,
          rating.value,
          card.state.box,
          next.box,
          clock,
          clock,
        ],
      );
      _db.raw.execute('COMMIT');
    } on Object {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
  }
}

/// Renders a row as JSON. Used by the debug view that shows what the outbox
/// will push -- being able to read the sync payload in the UI and in the
/// browser's Network tab is why giki speaks JSON.
String debugJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
