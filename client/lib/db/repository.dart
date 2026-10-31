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
import 'page_cards.dart';
import 'search.dart';

/// A node as shown in lists.
class NodeSummary {
  const NodeSummary(
      {required this.id, required this.title, required this.updatedAt});

  final String id;
  final String title;
  final String updatedAt;
}

/// A page that pages link to but that does not exist yet.
class WantedPage {
  const WantedPage({required this.title, required this.linkedFrom});

  /// The title as one of the linking pages writes it.
  final String title;

  /// The titles of the pages that link to it.
  final List<String> linkedFrom;
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

  /// Live nodes whose title or body matches [input], best match first.
  List<SearchHit> search(String input) => searchNodes(_db.raw, input);

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

  /// Creates a node, or updates the one with [id] -- restoring it if it was
  /// deleted, since saving text into a tombstone would hide it everywhere.
  ///
  /// Returns the node's id, so the caller can navigate to a page that was just
  /// created by following a dangling link.
  String save({String? id, required String title, required String body}) {
    final nodeId = id ?? newId();
    final now = nowClock();
    final titleKey = normalizeTitle(title);
    // The page, its links and its cards in one transaction: a tab closed
    // half-way must not leave a page in the outbox without the cards its
    // text promises -- other devices never derive them themselves.
    _db.raw.execute('BEGIN IMMEDIATE');
    try {
      // What the page said before, to tell which card lines this save
      // touched. A deleted page had none: restoring it writes them all.
      final previous = _db.raw.select(
        'SELECT body FROM nodes WHERE id = ? AND is_deleted = 0',
        [nodeId],
      );
      final before = previous.isEmpty ? '' : previous.first['body'] as String;
      _db.raw.execute(
        'INSERT INTO nodes (id, title, title_key, body, created_at, created_by, '
        '                   updated_at, updated_by, is_deleted) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0) '
        'ON CONFLICT (id) DO UPDATE SET '
        '  title = excluded.title, title_key = excluded.title_key, '
        '  body = excluded.body, updated_at = excluded.updated_at, '
        '  updated_by = excluded.updated_by, is_deleted = 0',
        [nodeId, title, titleKey, body, now, _db.userId, now, _db.userId],
      );
      reindexLinks(_db.raw, nodeId);
      syncPageCards(_db.raw,
          nodeId: nodeId,
          before: before,
          after: body,
          userId: _db.userId,
          now: now);
      _db.raw.execute('COMMIT');
    } on Object {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
    return nodeId;
  }

  /// Tombstones a node. The row stays, so the deletion can be replicated to
  /// devices that are still offline.
  ///
  /// The cards the page wrote with `question :: answer` lines are deleted
  /// with it; restoring the page writes them again.
  ///
  /// Returns the deletion's clock, which [undoDelete] needs.
  String delete(String id) {
    final now = nowClock();
    _db.raw.execute('BEGIN IMMEDIATE');
    try {
      final previous = _db.raw.select(
        'SELECT body FROM nodes WHERE id = ? AND is_deleted = 0',
        [id],
      );
      _db.raw.execute(
        'UPDATE nodes SET is_deleted = 1, updated_at = ?, updated_by = ? WHERE id = ?',
        [now, _db.userId, id],
      );
      reindexLinks(_db.raw, id);
      if (previous.isNotEmpty) {
        syncPageCards(_db.raw,
            nodeId: id,
            before: previous.first['body'] as String,
            after: '',
            userId: _db.userId,
            now: now);
      }
      _db.raw.execute('COMMIT');
    } on Object {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
    return now;
  }

  /// Takes back the [delete] of [id] that returned [deletedAt]: the page and
  /// the cards that deletion took with it come back exactly as they were --
  /// including a card's answer fixed on the Study page, which saving the
  /// page's text again would overwrite.
  ///
  /// Does nothing, and returns false, once anything else has happened to
  /// the page since: restored or deleted again, here or on another device.
  /// An Undo pressed late must not overwrite what came after it.
  bool undoDelete(String id, String deletedAt) {
    final now = nowClock();
    _db.raw.execute('BEGIN IMMEDIATE');
    try {
      final restored = _db.raw.select(
        'UPDATE nodes SET is_deleted = 0, updated_at = ?, updated_by = ? '
        'WHERE id = ? AND is_deleted = 1 AND updated_at = ? RETURNING id',
        [now, _db.userId, id, deletedAt],
      );
      if (restored.isNotEmpty) {
        reindexLinks(_db.raw, id);
        _db.raw.execute(
          'UPDATE cards SET is_deleted = 0, updated_at = ?, updated_by = ? '
          'WHERE node_id = ? AND is_deleted = 1 AND updated_at = ?',
          [now, _db.userId, id, deletedAt],
        );
      }
      _db.raw.execute('COMMIT');
      return restored.isNotEmpty;
    } on Object {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
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

  /// The pages that are linked to but do not exist, most wanted first --
  /// the wiki's to-do list.
  List<WantedPage> wanted() {
    final rows = _db.raw.select(
      'SELECT l.target_title_key AS key, s.id AS source, s.title, s.body '
      'FROM links l '
      'JOIN nodes s ON s.id = l.source_node_id AND s.is_deleted = 0 '
      'WHERE NOT EXISTS (SELECT 1 FROM nodes n '
      '  WHERE n.title_key = l.target_title_key AND n.is_deleted = 0) '
      'ORDER BY l.target_title_key, s.updated_at DESC',
    );
    final titles = <String, String>{};
    final from = <String, List<String>>{};
    // One parse per linking page, however many missing pages it links to.
    final targetsOf = <String, List<String>>{};
    for (final row in rows) {
      final key = row['key'] as String;
      (from[key] ??= []).add(row['title'] as String);
      // links keeps only the normalized key; the linking pages have the
      // capitalisation their authors chose. Any is better than none.
      if (titles[key] == null || titles[key] == key) {
        titles[key] = targetsOf
            .putIfAbsent(row['source'] as String,
                () => linkTargets(row['body'] as String))
            .firstWhere((target) => normalizeTitle(target) == key,
                orElse: () => key);
      }
    }
    final wanted = [
      for (final MapEntry(:key, :value) in from.entries)
        WantedPage(title: titles[key]!, linkedFrom: value),
    ]..sort((a, b) {
        final byCount = b.linkedFrom.length.compareTo(a.linkedFrom.length);
        return byCount != 0
            ? byCount
            : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    return wanted;
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
    this.nodeId = '',
    this.pageTitle,
  });

  final String cardId;
  final String front;
  final String back;
  final ReviewState state;

  /// The page the card belongs to; empty for a card made on the Study page.
  final String nodeId;

  /// That page's title, or null when there is no such page (any more).
  final String? pageTitle;
}

/// Reads and writes flashcards and their scheduling state.
class CardRepository {
  CardRepository(this._db);

  final GikiDatabase _db;

  /// Creates or updates a flashcard, optionally attached to a node.
  ///
  /// Without [nodeId], an update keeps the card's page: editing the text of a
  /// card must not detach it.
  String save(
      {String? id,
      String? nodeId,
      required String front,
      required String back}) {
    final cardId = id ?? newId();
    final now = nowClock();
    _db.raw.execute(
      'INSERT INTO cards (id, node_id, front, back, created_at, created_by, '
      '                   updated_at, updated_by, is_deleted) '
      "VALUES (?, COALESCE(?, ''), ?, ?, ?, ?, ?, ?, 0) "
      'ON CONFLICT (id) DO UPDATE SET '
      '  node_id = CASE WHEN ? IS NULL THEN node_id ELSE excluded.node_id END, '
      '  front = excluded.front, back = excluded.back, '
      '  updated_at = excluded.updated_at, updated_by = excluded.updated_by',
      [cardId, nodeId, front, back, now, _db.userId, now, _db.userId, nodeId],
    );
    return cardId;
  }

  /// Changes the text of card [id], keeping its page and schedule.
  ///
  /// Returns false, and writes nothing, when the card is gone: deleted on
  /// another device while it was being edited here. An edit written into
  /// the tombstone would sync to every device and be shown on none.
  bool update(String id, {required String front, required String back}) =>
      _db.raw.select(
        'UPDATE cards SET front = ?, back = ?, updated_at = ?, updated_by = ? '
        'WHERE id = ? AND is_deleted = 0 RETURNING id',
        [front, back, nowClock(), _db.userId, id],
      ).isNotEmpty;

  /// Deletes a card on every device. Its schedule and history stay: they are
  /// the user's record, and a card restored elsewhere picks them up again.
  ///
  /// Returns false, and writes nothing, when the card was deleted already: a
  /// fresh stamp on the tombstone would sync as a second deletion, and an
  /// Undo of the first (NodeRepository.undoDelete) would no longer find it.
  bool delete(String id) => _db.raw.select(
        'UPDATE cards SET is_deleted = 1, updated_at = ?, updated_by = ? '
        'WHERE id = ? AND is_deleted = 0 RETURNING id',
        [nowClock(), _db.userId, id],
      ).isNotEmpty;

  /// The cards due for the current user, soonest first.
  List<DueCard> due({DateTime? at, int limit = 50}) {
    final deadline = formatClock(at ?? DateTime.now());
    final rows = _db.raw.select(
      'SELECT c.id AS card_id, c.front, c.back, c.node_id, n.title AS page_title, '
      '       s.box, s.interval_days, s.reps, s.lapses, s.due_at '
      'FROM cards c '
      "LEFT JOIN nodes n ON n.id = c.node_id AND c.node_id != '' AND n.is_deleted = 0 "
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
          nodeId: row['node_id'] as String,
          pageTitle: row['page_title'] as String?,
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
    final clock = at == null ? nowClock() : formatClock(at);
    observeClock(clock);

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
