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

  group('editing a card through its line', () {
    const nodeId = 'page-1';
    const body = 'Notes\n\n'
        '- [ ] Capital of Mali :: Bamako\r\n'
        '  1. Capital of Chad :: N\'Djamena\n'
        '```\nCapital of Mali :: not a card\n```\n'
        'Capital of Chad :: a repeat, not the card';
    String idOf(String question) => pageCardId(nodeId, cardKey(question));
    CardLineAt lineOf(String question) =>
        pageCardLine(body, nodeId: nodeId, cardId: idOf(question))!;

    test('finds the line that writes a card, not a repeat or code', () {
      expect(lineOf('Capital of Chad').lineIndex, 3);
      expect(lineOf('capital  of mali').prefix, '- [ ] ');
      expect(pageCardLine(body, nodeId: nodeId, cardId: 'hand-made'), isNull);
      expect(
          pageCardLine(body,
              nodeId: 'other-page', cardId: idOf('Capital of Mali')),
          isNull);
    });

    test('rewrites the answer and keeps indentation, marker and line ending',
        () {
      final edited = editPageCardLine(body, lineOf('Capital of Mali'),
          front: 'Capital of Mali', back: 'Bamako (since 1960)')!;
      expect(edited.split('\n')[2],
          '- [ ] Capital of Mali :: Bamako (since 1960)\r');
      final chad = editPageCardLine(body, lineOf('Capital of Chad'),
          front: 'Capital of Chad', back: 'Ndjamena')!;
      expect(chad.split('\n')[3], '  1. Capital of Chad :: Ndjamena');
      expect(parseCardLines(chad),
          contains(const CardLine('Capital of Chad', 'Ndjamena')));
    });

    test('removes the line', () {
      final edited = editPageCardLine(body, lineOf('Capital of Mali'))!;
      expect(edited, isNot(contains('Bamako')));
      expect(edited.split('\n').length, body.split('\n').length - 1);
    });

    test('refuses text that would not read back as the card', () {
      final mali = lineOf('Capital of Mali');
      expect(editPageCardLine(body, mali, front: 'A :: B', back: 'C'), isNull);
      expect(
          editPageCardLine(body, mali, front: 'two\nlines', back: 'C'), isNull);
      expect(editPageCardLine(body, mali, front: '`odd', back: 'C'), isNull);
      // Asked further up already: the edited line would be the repeat.
      expect(
          editPageCardLine(body, lineOf('Capital of Chad'),
              front: 'Capital of Mali', back: 'C'),
          isNull);
    });

    test('refuses edits that would change another card of the page', () {
      const page = 'A :: 1\nB :: 2\nA :: repeat';
      CardLineAt at(String q) => pageCardLine(page,
          nodeId: nodeId, cardId: pageCardId(nodeId, cardKey(q)))!;
      // B asked again further down: the two lines would be one card.
      expect(editPageCardLine(page, at('A'), front: 'B', back: 'x'), isNull);
      // Removing A would only hand card A to the repeat.
      expect(editPageCardLine(page, at('A')), isNull);
      // Removing B is fine: the lines below it just move up.
      expect(editPageCardLine(page, at('B')), 'A :: 1\nA :: repeat');
      expect(editPageCardLine(page, at('B'), front: 'C', back: '3'),
          'A :: 1\nC :: 3\nA :: repeat');
    });
  });
}
