// Runs on the VM only: it uses the native SQLite to apply the real schema,
// which cannot even be compiled for the browser. That is why it lives outside
// test/, which CI also runs in Chrome.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:giki/db/ids.dart';
import 'package:giki/db/page_cards.dart';
import 'package:giki/srs/card_text.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  group('parseCardLines', () {
    test('one card per question :: answer line', () {
      expect(
        parseCardLines('Intro text.\n'
            'Capital of France :: Paris\n'
            '- Leitner boxes :: a ladder of review intervals\n'
            '1. Ebbinghaus :: forgetting curve\n'
            '- [ ] Task question :: task answer\n'
            'not a card: no spaces::here\n'),
        const [
          CardLine('Capital of France', 'Paris'),
          CardLine('Leitner boxes', 'a ladder of review intervals'),
          CardLine('Ebbinghaus', 'forgetting curve'),
          CardLine('Task question', 'task answer'),
        ],
      );
    });

    test('code is not cards', () {
      expect(
        parseCardLines('```cpp\nstd :: vector\n```\n'
            '~~~\nmain :: IO ()\n~~~\n'
            '````\n```dart\ninner :: fence\n```\nstill :: code\n````\n'
            '    indented :: code\n'
            'use `std :: vector` here\n'
            'after :: fence'),
        const [CardLine('after', 'fence')],
      );
    });

    test('empty sides and repeated questions are skipped', () {
      expect(
        parseCardLines(' :: no question\nno answer :: \n'
            'Same :: first\nsame  :: second'),
        const [CardLine('Same', 'first')],
      );
    });

    test('the answer may contain the separator again', () {
      expect(parseCardLines('a :: b :: c'), const [CardLine('a', 'b :: c')]);
    });
  });

  group('syncPageCards', () {
    late Database db;
    setUp(() {
      db = sqlite3.openInMemory();
      for (final name in ['schema.sql', 'schema_client.sql']) {
        db.execute(File('assets/db/$name').readAsStringSync());
      }
    });
    tearDown(() => db.close());

    var page = '';
    PageCardChanges edit(String after,
        {String now = '2026-10-28T10:00:00.000Z'}) {
      final changes = syncPageCards(db,
          nodeId: 'page',
          before: page,
          after: after,
          userId: 'alice',
          now: now);
      page = after;
      return changes;
    }

    setUp(() => page = '');

    List<String> live() => [
          for (final row in db.select(
              'SELECT front, back FROM cards WHERE is_deleted = 0 ORDER BY front'))
            '${row['front']} :: ${row['back']}',
        ];

    int outbox() =>
        db.select('SELECT count(*) AS n FROM sync_outbox').first['n'] as int;

    test('lines create, change, and remove cards', () {
      var changes = edit('A :: 1\nB :: 2');
      expect((changes.created, changes.updated, changes.deleted), (2, 0, 0));
      expect(live(), ['A :: 1', 'B :: 2']);

      changes = edit('a :: one\nC :: 3');
      expect((changes.created, changes.updated, changes.deleted), (1, 1, 1));
      expect(live(), ['C :: 3', 'a :: one']);
      // Same question, so the same card -- and the same review schedule.
      expect(
        db.select('SELECT id FROM cards WHERE front = ?', ['a']).single['id'],
        pageCardId('page', 'a'),
      );
    });

    test('saving unchanged lines writes nothing', () {
      edit('A :: 1');
      final before = outbox();
      expect(edit('A :: 1\n\nmore prose').isEmpty, isTrue);
      expect(outbox(), before);
    });

    test('a card edited or deleted elsewhere stays so until its line changes',
        () {
      edit('A :: 1\nB :: 2');
      final a = pageCardId('page', 'a');
      final b = pageCardId('page', 'b');
      db.execute(
          "UPDATE cards SET back = 'fixed on the Study page' WHERE id = ?",
          [a]);
      db.execute('UPDATE cards SET is_deleted = 1 WHERE id = ?', [b]);

      // An unrelated edit of the page.
      edit('A :: 1\nB :: 2\n\nA new paragraph.');
      expect(live(), ['A :: fixed on the Study page']);

      // Editing a line is a decision about that card.
      edit('A :: 1\nB :: two\n\nA new paragraph.');
      expect(live(), ['A :: fixed on the Study page', 'B :: two']);
    });

    test('a card whose question was edited elsewhere still goes with its line',
        () {
      edit('A :: 1');
      db.execute("UPDATE cards SET front = 'Rephrased' WHERE id = ?",
          [pageCardId('page', 'a')]);
      expect(edit('').deleted, 1);
      expect(live(), isEmpty);
    });

    test('a hand-made card on the page is left alone', () {
      db.execute(
        "INSERT INTO cards (id, node_id, front, back, created_at, updated_at) "
        "VALUES ('random-id', 'page', 'Manual', 'card', 'x', 'x')",
      );
      edit('A :: 1');
      edit('');
      expect(live(), ['Manual :: card']);
    });

    test('deleting the page deletes its cards; restoring brings them back', () {
      edit('A :: 1');
      expect(edit('').deleted, 1);
      expect(live(), isEmpty);
      expect(edit('A :: 1').created, 1);
      expect(live(), ['A :: 1']);
    });
  });
}
