// End-to-end test of the loop that nothing else covers: a real browser, the
// real SQLite-Wasm database with its real triggers, the real sync worker, and
// a real giki server over HTTP.
//
// Everything else in CI tests one side in isolation. This is the only place
// where an edit travels the whole way -- trigger to outbox to HTTP to the
// server's SQLite and back as a delta -- which is exactly where a bug would
// quietly lose a user's writing.
//
// Run it with tool/e2e.sh, which starts the server and chromedriver for you.
//
// The tests share one database and run in declaration order: each phase builds
// on the state the previous one left behind, the way a real session does. The
// phases that depend on an earlier one say so and assert their precondition,
// so a failure reads as "phase 1 broke" rather than as a null dereference.
//
// About clocks: this client writes with the real clock, and the simulated
// second device always writes in the past, relative to a baseline captured
// before the first local write. Hardcoding a wall-clock date instead would
// make the suite depend on the day the runner thinks it is -- and would have
// made this test unpassable on any machine whose clock sits before that date.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giki/auth/webauthn.dart';
import 'package:giki/auth/webauthn_json.dart';
import 'package:giki/db/attachments.dart';
import 'package:giki/db/clock.dart';
import 'package:giki/db/database.dart';
import 'package:giki/db/ids.dart';
import 'package:giki/db/link_index.dart';
import 'package:giki/db/srs_merge.dart';
import 'package:giki/db/repository.dart';
import 'package:giki/db/search.dart';
import 'package:giki/main.dart';
import 'package:giki/pages/history_page.dart';
import 'package:giki/pages/settings_page.dart';
import 'package:giki/pages/study_page.dart';
import 'package:giki/pages/wiki_page.dart';
import 'package:giki/srs/srs.dart';
import 'package:giki/sync/api_client.dart';
import 'package:giki/sync/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

/// Where the server under test listens, passed in by tool/e2e.sh.
const String serverUrl = String.fromEnvironment('GIKI_E2E_SERVER');

/// A bearer token the server maps to the user id in [expectedUser].
const String token = String.fromEnvironment('GIKI_E2E_TOKEN');

/// The user id the server derives from [token].
const String expectedUser = String.fromEnvironment('GIKI_E2E_USER');

/// What this client claims its user is. Deliberately *not* [expectedUser]:
/// the audit trail must record the authenticated session, not whatever the
/// payload says, and an assertion where the two agree cannot show that.
const String claimedUser = 'payload-claimed-user';

/// A second device, simulated with plain HTTP calls. It is what makes this a
/// multi-device test rather than a round trip to a mirror.
const String otherDeviceId = 'e2e-second-device';

/// The token tool/e2e.sh configures for registering a new account.
const String e2eRegisterToken =
    String.fromEnvironment('GIKI_E2E_REGISTER_TOKEN');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late GikiDatabase db;
  late NodeRepository nodes;
  late SyncApiClient api;
  late SyncService sync;
  late Uri baseUrl;

  // A fresh storage name per run: the browser keeps IndexedDB between runs, and
  // a test that passes only on an empty database is a test that passes once.
  final storageName = 'giki-e2e-${DateTime.now().microsecondsSinceEpoch}';

  // Captured before the first local write, so "baseline minus an hour" is
  // reliably older than anything this client writes afterwards.
  final baseline = DateTime.now().toUtc();
  String clockBefore(Duration howLong) =>
      formatClock(baseline.subtract(howLong));

  String? leitnerId;
  const srsId = 'e2e-node-spaced-repetition';

  setUpAll(() async {
    expect(
      serverUrl,
      isNotEmpty,
      reason: 'pass --dart-define=GIKI_E2E_SERVER=http://host:port',
    );
    baseUrl = Uri.parse(serverUrl);
    db = await GikiDatabase.open(storageName: storageName);
    db.setMeta(MetaKeys.userId, claimedUser);
    nodes = NodeRepository(db);
    api = SyncApiClient(baseUrl: baseUrl, token: token);
    sync = SyncService(db: db, api: api);
  });

  tearDownAll(() async {
    await sync.dispose();
    api.close();
    db.close();
  });

  /// Posts a sync batch as a second device, bypassing this client entirely.
  Future<Map<String, Object?>> syncAsOtherDevice({
    int cursor = 0,
    List<Map<String, Object?>> mutations = const [],
  }) async {
    final response = await http.post(
      baseUrl.resolve('api/v1/sync'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'device_id': otherDeviceId,
        'cursor': cursor,
        'mutations': mutations,
      }),
    );
    expect(response.statusCode, 200, reason: response.body);
    return jsonDecode(response.body) as Map<String, Object?>;
  }

  /// Builds a full `nodes` row the way the client's trigger would.
  ///
  /// `created_by`/`updated_by` carry [claimedUser] here too: the server must
  /// take the actor from the session for this device as well.
  Map<String, Object?> nodeMutation({
    required int clientSeq,
    required String id,
    required String title,
    required String body,
    required String clock,
    String op = 'UPDATE',
  }) {
    return {
      'client_seq': clientSeq,
      'table': 'nodes',
      'record_id': id,
      'op': op,
      'updated_at': clock,
      'payload': {
        'id': id,
        'title': title,
        'title_key': title.toLowerCase(),
        'body': body,
        'created_at': clock,
        'created_by': claimedUser,
        'updated_at': clock,
        'updated_by': claimedUser,
        'is_deleted': 0,
      },
    };
  }

  /// Reads one record's audit trail straight from the server.
  Future<List<Map<String, Object?>>> history(String table, String id) async {
    final response = await http.get(
      baseUrl.resolve('api/v1/history?table=$table&record_id=$id'),
      headers: {'Authorization': 'Bearer $token'},
    );
    expect(response.statusCode, 200, reason: response.body);
    final decoded = jsonDecode(response.body) as Map<String, Object?>;
    return [
      for (final entry in decoded['history'] as List<Object?>)
        entry as Map<String, Object?>,
    ];
  }

  /// The payload of the newest change the server holds for [id].
  Future<Map<String, Object?>> latestServerPayload(String id) async {
    final entries = await history('nodes', id);
    expect(entries, isNotEmpty, reason: 'the server has no record of $id');
    return entries.last['payload'] as Map<String, Object?>;
  }

  testWidgets('a local edit reaches the server through the outbox', (_) async {
    expect(db.pendingCount, 0, reason: 'a fresh database has an empty outbox');

    leitnerId = nodes.save(
      title: 'Leitner',
      body: 'Five boxes. See [[Spaced Repetition]].',
    );

    // Nothing in Dart wrote this row: the SQLite trigger did, from the same
    // statement that saved the page.
    expect(db.pendingCount, 1, reason: 'the outbox trigger did not fire');
    final pending = db.readOutbox().single;
    expect(pending.table, 'nodes');
    expect(pending.recordId, leitnerId);
    final payload = jsonDecode(pending.payload) as Map<String, Object?>;
    expect(payload['title'], 'Leitner');
    expect(
      payload['title_key'],
      'leitner',
      reason: 'the trigger payload carries the normalized link target',
    );

    final report = await sync.syncOnce();
    expect(report.applied, 1, reason: report.toString());
    expect(report.rejected, isEmpty, reason: report.rejected.toString());
    expect(db.pendingCount, 0, reason: 'the outbox was not cleared');
    expect(report.cursor, greaterThan(0));
    expect(db.cursor, report.cursor, reason: 'the local cursor was not stored');

    // The server does not send a device its own change back. Without that
    // filter this push would return as a delta and the client would keep
    // re-applying what it just wrote.
    expect(
      report.pulled,
      0,
      reason: 'the device received its own change back as a delta',
    );

    // The server has it, and recorded who wrote it. The payload claims
    // claimedUser; the audit trail must say expectedUser, which is the user
    // the bearer token authenticates.
    final entries = await history('nodes', leitnerId!);
    expect(entries, hasLength(1));
    expect(
      entries.single['actor_user_id'],
      expectedUser,
      reason:
          'the audit trail took the actor from the payload, not the session',
    );
    expect(entries.single['origin_device_id'], db.deviceId);
    expect(
      (entries.single['payload'] as Map<String, Object?>)['created_by'],
      claimedUser,
      reason: 'the row itself keeps what the client wrote',
    );
  });

  testWidgets('backlinks are derived locally, with no server involved', (
    _,
  ) async {
    expect(leitnerId, isNotNull, reason: 'phase 1 must have created the page');

    // The link target does not exist yet. A dangling link is normal in a wiki
    // and must not stop the backlink index from working.
    final backlinks = nodes.backlinks('spaced repetition');
    expect(backlinks, hasLength(1));
    expect(backlinks.single.title, 'Leitner');
  });

  testWidgets("another device's change arrives and does not echo back", (
    _,
  ) async {
    final cursorBefore = db.cursor;
    await syncAsOtherDevice(
      mutations: [
        nodeMutation(
          clientSeq: 1,
          id: srsId,
          op: 'INSERT',
          title: 'Spaced Repetition',
          body: 'Review just before you would forget.',
          clock: clockBefore(const Duration(hours: 1)),
        ),
      ],
    );

    final report = await sync.syncOnce();
    expect(report.pulled, 1, reason: report.toString());
    expect(report.cursor, greaterThan(cursorBefore));

    // The delta landed in the local database...
    final arrived = nodes.byTitle('Spaced Repetition');
    expect(arrived, isNotNull, reason: 'the delta was not written locally');
    expect(arrived!.body, 'Review just before you would forget.');

    // ...and the triggers did not turn that write into a new outbox row. This
    // is the echo loop the sync_mute table exists to break; without it the
    // client would push this row straight back on the next sync, forever.
    expect(
      db.pendingCount,
      0,
      reason: 'applying a delta produced outbox rows: the mute guard failed',
    );

    // Syncing again is a no-op: convergence, not a ping-pong.
    final second = await sync.syncOnce();
    expect(second.pulled, 0);
    expect(second.pushed, 0);
  });

  testWidgets('an older delta does not overwrite a newer local edit', (
    _,
  ) async {
    // The other device edits the page it created. Its clock is newer than the
    // version the server holds, so the server accepts it...
    await syncAsOtherDevice(
      mutations: [
        nodeMutation(
          clientSeq: 2,
          id: srsId,
          title: 'Spaced Repetition',
          body: 'edit from the other device',
          clock: clockBefore(const Duration(minutes: 30)),
        ),
      ],
    );

    // ...but before we sync, the user edits the same page here, with the real
    // clock -- later than anything the other device sent.
    nodes.save(
      id: srsId,
      title: 'Spaced Repetition',
      body: 'the local edit the user is still typing',
    );
    expect(db.pendingCount, 1);

    final report = await sync.syncOnce();
    expect(report.applied, 1, reason: 'our newer edit should win: $report');
    expect(report.pulled, greaterThanOrEqualTo(1));

    // The incoming delta is older than the row we hold, so it must not
    // overwrite it -- Last-Write-Wins applies locally too, not just server
    // side.
    final node = nodes.byId(srsId);
    expect(
      node!.body,
      'the local edit the user is still typing',
      reason: 'an older delta clobbered a newer local edit',
    );

    // And the server agrees, so a third device would see the same text.
    final payload = await latestServerPayload(srsId);
    expect(payload['body'], 'the local edit the user is still typing');
  });

  testWidgets('a stale push is reported, and never reaches a client', (
    _,
  ) async {
    // The other device retries an edit from before the current version. The
    // server must say "stale" rather than accept it or fail the batch.
    final response = await syncAsOtherDevice(
      mutations: [
        nodeMutation(
          clientSeq: 3,
          id: srsId,
          title: 'Spaced Repetition',
          body: 'a resurrected offline edit',
          clock: clockBefore(const Duration(hours: 2)),
        ),
      ],
    );
    final results =
        (response['results'] as List<Object?>).cast<Map<String, Object?>>();
    expect(results.single['status'], 'stale');
    expect(results.single['reason'], isNotEmpty);

    // A rejected-as-stale mutation must not become a delta either: sync and
    // check that the losing text never arrives here.
    await sync.syncOnce();
    final node = nodes.byId(srsId);
    expect(
      node!.body,
      'the local edit the user is still typing',
      reason: 'a stale mutation reached a client as a delta',
    );
  });

  testWidgets('a deletion replicates as a tombstone', (_) async {
    expect(leitnerId, isNotNull, reason: 'phase 1 must have created the page');

    nodes.delete(leitnerId!);
    expect(nodes.byId(leitnerId!), isNull, reason: 'the page is gone locally');

    final report = await sync.syncOnce();
    expect(report.applied, 1, reason: report.toString());
    expect(
      report.pulled,
      0,
      reason: 'the device received its own deletion back as a delta',
    );

    // The server recorded the deletion as a tombstone rather than a removal.
    final payload = await latestServerPayload(leitnerId!);
    expect(payload['is_deleted'], 1);

    // Proof that the row itself survived, which the ChangeLog alone cannot
    // give: the ChangeLog is append-only, so its entries would look identical
    // after a hard DELETE. Push an older edit for the same id -- if the row is
    // still there with its tombstone timestamp, Last-Write-Wins rejects this
    // as stale; if the row had been deleted, there would be nothing to compare
    // against and the server would happily insert it.
    final response = await syncAsOtherDevice(
      mutations: [
        nodeMutation(
          clientSeq: 4,
          id: leitnerId!,
          title: 'Leitner',
          body: 'an edit from before the deletion',
          clock: clockBefore(const Duration(hours: 3)),
        ),
      ],
    );
    final results =
        (response['results'] as List<Object?>).cast<Map<String, Object?>>();
    expect(
      results.single['status'],
      'stale',
      reason: 'the tombstoned row is gone from the server: it was hard-deleted',
    );

    // And a device that was offline through all of this is told about the
    // deletion, rather than silently never hearing about the record.
    final fromScratch = await syncAsOtherDevice(cursor: 0);
    final tombstone = (fromScratch['changes'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((c) => c['record_id'] == leitnerId)
        .last;
    expect((tombstone['payload'] as Map<String, Object?>)['is_deleted'], 1);
  });

  passkeyTests(baseUrl: () => baseUrl, registerToken: () => e2eRegisterToken);

  testWidgets('the sync badge follows the outbox, not the last rebuild', (
    tester,
  ) async {
    // The badge is the only signal giki gives that work has not reached the
    // server. It used to be read once per shell build, so an edit made in a
    // child route left it saying "Sync now" with changes queued.
    expect(db.pendingChanges.value, db.pendingCount);

    final before = db.pendingChanges.value;
    nodes.save(title: 'Badge Check', body: 'written without touching the UI');

    // SQLite's update hook is asynchronous, so give it a turn -- as the real
    // app does between a save and the next frame.
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      db.pendingChanges.value,
      before + 1,
      reason: 'the outbox grew but the notifier did not follow',
    );

    // And it comes back down once the outbox drains.
    await sync.syncOnce();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      db.pendingChanges.value,
      0,
      reason: 'the notifier did not follow the outbox being cleared',
    );

    // Leave the knowledge base as the later phases expect it.
    nodes.delete(nodes.byTitle('Badge Check')!.id);
    await sync.syncOnce();
  });

  /// Writes a newer version of a node into the local database the way the
  /// sync worker does -- through applyDeltas, under sync_mute -- as if another
  /// device had edited it and this one had just pulled the change.
  ///
  /// The payload is the full row, as the server's ChangeLog always holds it:
  /// the server stamps created_at onto every row it accepts. An early version
  /// of this helper sent a partial row, and the NOT NULL constraint on
  /// created_at rejected it -- a test bug, but a reminder that a delta is a
  /// whole row, never a patch.
  void receiveRemoteEdit(String id, String body, {bool deleted = false}) {
    final node = nodes.byId(id)!;
    final createdAt = db.raw.select(
        'SELECT created_at, created_by FROM nodes WHERE id = ?', [id]).first;
    // Later than anything this client has written, whatever its clock has
    // been pulled forward to by earlier phases.
    final clock =
        formatClock(parseClock(nowClock()).add(const Duration(seconds: 1)));
    db.applyDeltas([
      Delta(
        seq: 0,
        table: 'nodes',
        recordId: id,
        op: 'UPDATE',
        payload: {
          'id': id,
          'title': node.title,
          'title_key': node.titleKey,
          'body': body,
          'created_at': createdAt['created_at'],
          'created_by': createdAt['created_by'],
          'updated_at': clock,
          'updated_by': 'another-device-user',
          'is_deleted': deleted ? 1 : 0,
        },
      ),
    ], db.cursor);
  }

  /// Opens [id] the way a user does, then switches it to editing: an
  /// existing page opens rendered, for reading.
  Future<void> openEditor(WidgetTester tester, String id) async {
    await tester.pumpWidget(MaterialApp(
      home: NodeEditor(db: db, nodes: nodes, nodeId: id),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
  }

  // The scenario exploratory testing found: pressing Save on a page you never
  // touched used to stamp it with a fresh updated_at, which under
  // Last-Write-Wins beat a newer edit from another device and erased it.
  testWidgets('saving an unchanged page writes nothing', (tester) async {
    final id = nodes.save(title: 'Untouched', body: 'as it was');
    await sync.syncOnce();
    final versionBefore = nodes.byId(id)!.updatedAt;
    final pendingBefore = db.pendingCount;

    await openEditor(tester, id);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(db.pendingCount, pendingBefore,
        reason: 'an unchanged save queued a write');
    expect(nodes.byId(id)!.updatedAt, versionBefore,
        reason: 'an unchanged save gave the page a new timestamp');
    expect(find.text('No changes to save.'), findsOneWidget);
  });

  // The ordinary case, and the one an earlier version of the fix broke: the
  // "unchanged" check captured the typed text as the saved text, so editing an
  // existing page and pressing Save wrote nothing at all.
  testWidgets('editing an existing page and saving writes it', (tester) async {
    final id = nodes.save(title: 'Editable', body: 'before');
    await sync.syncOnce();
    final pendingBefore = db.pendingCount;

    await openEditor(tester, id);
    await tester.enterText(find.byType(TextField).at(1), 'after');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(nodes.byId(id)!.body, 'after', reason: 'the edit was not saved');
    expect(db.pendingCount, pendingBefore + 1,
        reason: 'the edit was not queued for sync');
    expect(find.text('No changes to save.'), findsNothing);
  });

  testWidgets('an open editor shows a newer version that arrives',
      (tester) async {
    final id = nodes.save(title: 'Shared', body: 'the version I opened');
    await openEditor(tester, id);
    expect(find.text('the version I opened'), findsOneWidget);

    receiveRemoteEdit(id, 'the version another device wrote');
    // The update hook is asynchronous; give it a turn.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('the version another device wrote'), findsOneWidget,
        reason: 'the editor kept showing a stale body');
    expect(find.text('the version I opened'), findsNothing);
  });

  testWidgets('saving over a newer version asks first', (tester) async {
    final id = nodes.save(title: 'Contested', body: 'original');
    await openEditor(tester, id);

    // The user types; meanwhile another device's edit arrives.
    await tester.enterText(find.byType(TextField).at(1), 'my unsaved edit');
    await tester.pump();
    receiveRemoteEdit(id, 'their newer edit');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // The user's text is kept, and they are told.
    expect(find.text('my unsaved edit'), findsOneWidget);
    expect(find.textContaining('changed on another device'), findsWidgets);

    final pendingBefore = db.pendingCount;
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Changed on another device'), findsOneWidget,
        reason: 'Save overwrote a newer version without asking');

    // Choosing theirs writes nothing and shows their text.
    await tester.tap(find.text('Show their version'));
    await tester.pumpAndSettle();
    expect(db.pendingCount, pendingBefore,
        reason: 'choosing their version still wrote mine');
    expect(nodes.byId(id)!.body, 'their newer edit');
    expect(find.text('their newer edit'), findsOneWidget);
  });

  // Exploratory testing: a page deleted on another device while it was open
  // here gave no sign, and Save wrote the edit into the tombstone -- "Saved
  // locally", then the page and the text were gone from every device.
  testWidgets('an open page deleted elsewhere says so', (tester) async {
    final id = nodes.save(title: 'Doomed', body: 'still here');
    await openEditor(tester, id);

    receiveRemoteEdit(id, 'still here', deleted: true);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.textContaining('deleted on another device'), findsWidgets,
        reason: 'the editor gave no sign the page is gone');
    expect(find.text('still here'), findsOneWidget,
        reason: 'the text should stay visible, to copy or restore');
  });

  testWidgets('saving into a page deleted elsewhere asks first',
      (tester) async {
    final id = nodes.save(title: 'Doomed twice', body: 'original');
    await openEditor(tester, id);

    await tester.enterText(find.byType(TextField).at(1), 'typed after delete');
    await tester.pump();
    receiveRemoteEdit(id, 'original', deleted: true);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final pendingBefore = db.pendingCount;
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted on another device'), findsOneWidget,
        reason: 'Save wrote into a deleted page without asking');

    await tester.tap(find.text('Restore with my text'));
    await tester.pumpAndSettle();
    expect(nodes.byId(id)?.body, 'typed after delete',
        reason: 'the edit went into a tombstone instead of restoring the page');
    expect(db.pendingCount, pendingBefore + 1,
        reason: 'the restore was not queued for sync');
    expect(find.textContaining('deleted on another device'), findsNothing);
  });

  // Backlinks used to know only about pages saved on this device: deltas
  // upserted the row and skipped the derived link index.
  testWidgets('a page that arrives by sync shows up in backlinks', (_) async {
    void deliver(String id, String title, String body,
        {required DateTime clock, int deleted = 0}) {
      final stamp = formatClock(clock);
      db.applyDeltas([
        Delta(
          seq: 0,
          table: 'nodes',
          recordId: id,
          op: deleted == 1 ? 'DELETE' : 'UPDATE',
          payload: {
            'id': id,
            'title': title,
            'title_key': title.toLowerCase(),
            'body': body,
            'created_at': stamp,
            'created_by': 'another-device-user',
            'updated_at': stamp,
            'updated_by': 'another-device-user',
            'is_deleted': deleted,
          },
        ),
      ], db.cursor);
    }

    final now = DateTime.now().toUtc();
    deliver('synced-linker', 'Synced Linker', 'see [[Synced Target]]',
        clock: now);
    expect(nodes.backlinks('synced target').map((n) => n.title),
        contains('Synced Linker'),
        reason: 'a page that arrived by sync is missing from backlinks');

    // An older version the Last-Write-Wins guard rejects must not move the
    // index either: it is rebuilt from the stored row, not the payload.
    deliver('synced-linker', 'Synced Linker', 'now about [[Elsewhere]]',
        clock: now.subtract(const Duration(hours: 1)));
    expect(nodes.backlinks('synced target').map((n) => n.title),
        contains('Synced Linker'),
        reason: 'a rejected older delta rewrote the link index');
    expect(nodes.backlinks('elsewhere'), isEmpty);

    // A deletion that arrives by sync takes its links with it.
    deliver('synced-linker', 'Synced Linker', 'see [[Synced Target]]',
        clock: now.add(const Duration(seconds: 1)), deleted: 1);
    expect(nodes.backlinks('synced target'), isEmpty,
        reason: 'a deleted page still shows up in backlinks');
  });

  // A fix to how links are derived must also reach pages written before it.
  testWidgets('an upgraded device rebuilds its link index once', (_) async {
    final id = nodes.save(title: 'Old Linker', body: 'see [[Upgrade Target]]');

    // Recreate the state a device was left in before deltas maintained the
    // index: the page is there, its links are not, and the device has never
    // run the rebuild.
    db.raw.execute('DELETE FROM links WHERE source_node_id = ?', [id]);
    db.raw
        .execute('DELETE FROM sync_meta WHERE key = ?', [linkIndexVersionKey]);
    expect(nodes.backlinks('upgrade target'), isEmpty);

    expect(ensureLinkIndex(db.raw), greaterThan(0),
        reason: 'the rebuild did not run on an un-upgraded device');
    expect(nodes.backlinks('upgrade target').map((n) => n.title),
        contains('Old Linker'));

    // And only once.
    expect(ensureLinkIndex(db.raw), 0, reason: 'the rebuild ran again');
  });

  /// Delivers a review schedule the way the sync worker does.
  void deliverSchedule(String id, String cardId,
      {required int box, required DateTime due, required DateTime clock}) {
    final stamp = formatClock(clock);
    db.applyDeltas([
      Delta(
        seq: 0,
        table: 'srs_state',
        recordId: id,
        op: 'UPDATE',
        payload: {
          'id': id,
          'card_id': cardId,
          'user_id': db.userId,
          'box': box,
          'interval_days': 0,
          'ease': 2.5,
          'reps': 1,
          'lapses': 0,
          'due_at': formatClock(due),
          'last_reviewed_at': stamp,
          'created_at': stamp,
          'updated_at': stamp,
          'is_deleted': 0,
        },
      ),
    ], db.cursor);
  }

  int liveSchedules(String cardId) => db.raw.select(
      'SELECT COUNT(*) AS n FROM srs_state WHERE card_id = ? AND is_deleted = 0',
      [cardId]).first['n'] as int;

  // Exploratory testing found a card that, first reviewed on two devices,
  // never left the study queue: each device minted its own schedule row.
  testWidgets('a card reviewed on two devices keeps one schedule', (_) async {
    final cards = CardRepository(db);
    final cardId = cards.save(front: 'Two devices', back: 'one schedule');
    final card = cards.due().firstWhere((c) => c.cardId == cardId);
    cards.review(card, Rating.good);
    expect(liveSchedules(cardId), 1);

    // The other device computes the same id for its own first review, so its
    // version is a version of this row, not a second row.
    deliverSchedule(srsStateId(cardId, db.userId), cardId,
        box: 1,
        due: DateTime.now().toUtc(),
        clock: DateTime.now().toUtc().add(const Duration(seconds: 1)));
    expect(liveSchedules(cardId), 1,
        reason: 'the other device created a second schedule for the card');
  });

  testWidgets('a duplicate schedule from an old client cannot trap a card', (
    _,
  ) async {
    final cards = CardRepository(db);
    final cardId = cards.save(front: 'Stuck?', back: 'no');
    // What an older client produced: a schedule under a random id, due now.
    deliverSchedule('old-client-random-id', cardId,
        box: 1,
        due: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        clock: DateTime.now().toUtc());

    final card = cards.due().firstWhere((c) => c.cardId == cardId);
    cards.review(card, Rating.good);

    expect(cards.due().map((c) => c.cardId), isNot(contains(cardId)),
        reason: 'answered "good" and still due: the zombie card');
  });

  testWidgets('duplicate schedules are merged into one', (_) async {
    final cards = CardRepository(db);
    final cardId = cards.save(front: 'Merge me', back: 'once');
    final older = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final newer = DateTime.now().toUtc();
    deliverSchedule('dup-a', cardId, box: 2, due: newer, clock: older);
    deliverSchedule('dup-b', cardId, box: 4, due: newer, clock: newer);
    expect(liveSchedules(cardId), 2);

    expect(mergeDuplicateSchedules(db.raw), greaterThanOrEqualTo(1));
    expect(liveSchedules(cardId), 1);
    final survivor = db.raw.select(
        'SELECT id, box FROM srs_state WHERE card_id = ? AND is_deleted = 0',
        [cardId]).first;
    expect(survivor['id'], srsStateId(cardId, db.userId),
        reason: 'the survivor is not the row every device agrees on');
    expect(survivor['box'], 4, reason: 'the newest schedule did not win');
  });

  // Attachments: the row syncs like any other, the bytes travel separately
  // by hash. These phases pin the order that keeps the two consistent.
  testWidgets('an attachment reaches the server, bytes before the row',
      (_) async {
    final attachments = AttachmentRepository(db);
    final pageId = nodes.save(title: 'With a picture', body: 'see below');
    final bytes = Uint8List.fromList(utf8.encode('pretend this is a PNG'));
    final key = blobKey(bytes);
    attachments.add(
      nodeId: pageId,
      filename: 'picture.png',
      mimeType: guessMimeType('picture.png', ''),
      bytes: bytes,
    );
    expect(attachments.pendingUploads(), [key]);

    final report = await sync.syncOnce();
    expect(report.uploaded, 1);
    expect(report.rejected, isEmpty, reason: 'the server refused the row');
    expect(attachments.pendingUploads(), isEmpty,
        reason: 'the blob was not marked uploaded');

    final served = await api.getBlob(key);
    expect(served, bytes, reason: 'the server holds other bytes');
    final listed = attachments.forNode(pageId);
    expect(listed, hasLength(1));
    expect(listed.single.mimeType, 'image/png');
    expect(listed.single.isImage, isTrue);
  });

  testWidgets("another device's attachment arrives with its bytes", (_) async {
    final attachments = AttachmentRepository(db);
    final pageId = nodes.save(title: 'Shared file', body: '');
    await sync.syncOnce();

    // The other device uploads the blob first, then pushes the row.
    final bytes = Uint8List.fromList(utf8.encode('a file from elsewhere'));
    final key = blobKey(bytes);
    final put = await http.put(
      baseUrl.resolve('api/v1/blobs/$key'),
      headers: {'Authorization': 'Bearer $token'},
      body: bytes,
    );
    expect(put.statusCode, 200, reason: put.body);
    final clock = formatClock(DateTime.now().toUtc());
    const attachmentId = 'e2e-attachment-from-elsewhere';
    await syncAsOtherDevice(mutations: [
      {
        'client_seq': 1,
        'table': 'attachments',
        'record_id': attachmentId,
        'op': 'INSERT',
        'updated_at': clock,
        'payload': {
          'id': attachmentId,
          'node_id': pageId,
          'sha256': key,
          'filename': 'notes.txt',
          'mime_type': 'text/plain',
          'size': bytes.length,
          'created_at': clock,
          'created_by': claimedUser,
          'updated_at': clock,
          'updated_by': claimedUser,
          'is_deleted': 0,
        },
      },
    ]);

    await sync.syncUntilCaughtUp();
    final listed = attachments.forNode(pageId);
    expect(listed.map((a) => a.filename), ['notes.txt'],
        reason: 'the attachment row did not arrive');

    // Bytes are fetched on demand -- when a page showing them asks -- not
    // for every file in the shared knowledge base.
    expect(listed.single.hasBytes, isFalse,
        reason: 'the bytes were downloaded before anyone asked for them');
    db.wantBlobs([key]);
    await sync.fetchWantedBlobs();
    expect(attachments.forNode(pageId).single.hasBytes, isTrue,
        reason: 'asking for the bytes did not fetch them');
    expect(attachments.bytes(key), bytes);
    expect(db.wantedBlobs, isEmpty);

    // Removing it is an ordinary tombstone that reaches the server; the blob
    // stays, since another row may share it.
    attachments.delete(attachmentId);
    expect(attachments.forNode(pageId), isEmpty);
    expect(attachments.bytes(key), isNotNull);
    final report = await sync.syncOnce();
    expect(report.rejected, isEmpty);
    final everything = await syncAsOtherDevice();
    final tombstones = [
      for (final change in everything['changes']! as List<Object?>)
        if (change is Map<String, Object?> &&
            change['record_id'] == attachmentId)
          (change['payload']! as Map<String, Object?>)['is_deleted'],
    ];
    expect(tombstones.last, 1, reason: 'the removal never reached the server');
  });

  // Clients upload bytes before rows; the server enforces it regardless, so
  // no device can be handed a row it cannot download.
  testWidgets('the server refuses an attachment row without its bytes',
      (_) async {
    final clock = formatClock(DateTime.now().toUtc());
    final missing = blobKey(utf8.encode('never uploaded'));
    final response = await syncAsOtherDevice(mutations: [
      {
        'client_seq': 1,
        'table': 'attachments',
        'record_id': 'e2e-attachment-without-bytes',
        'op': 'INSERT',
        'updated_at': clock,
        'payload': {
          'id': 'e2e-attachment-without-bytes',
          'node_id': 'nowhere',
          'sha256': missing,
          'filename': 'ghost.png',
          'mime_type': 'image/png',
          'size': 1,
          'created_at': clock,
          'created_by': claimedUser,
          'updated_at': clock,
          'updated_by': claimedUser,
          'is_deleted': 0,
        },
      },
    ]);
    final results = response['results']! as List<Object?>;
    expect((results.single! as Map<String, Object?>)['status'], 'rejected');
  });

  testWidgets('fetched bytes that do not match their hash are dropped',
      (_) async {
    final attachments = AttachmentRepository(db);
    final key = blobKey(utf8.encode('the real thing'));
    expect(
        attachments.storeFetched(
            key, Uint8List.fromList(utf8.encode('an impostor'))),
        isFalse);
    expect(attachments.bytes(key), isNull);
  });

  testWidgets('an oversized file is refused before it reaches the outbox',
      (_) async {
    final attachments = AttachmentRepository(db);
    final pageId = nodes.save(title: 'Too big', body: '');
    final pendingBefore = db.pendingCount;
    expect(
      () => attachments.add(
        nodeId: pageId,
        filename: 'huge.bin',
        mimeType: '',
        bytes: Uint8List(maxAttachmentBytes + 1),
      ),
      throwsA(isA<AttachmentException>()),
    );
    expect(db.pendingCount, pendingBefore);
    expect(attachments.pendingUploads(), isEmpty);
  });

  // A file attached to a page another device had deleted was stored against
  // the tombstone: the server kept a live attachment row, and the page and
  // the file were invisible on every device.
  testWidgets('a file cannot be attached to a deleted page', (_) async {
    final attachments = AttachmentRepository(db);
    final pageId = nodes.save(title: 'Gone', body: 'scans');
    receiveRemoteEdit(pageId, 'scans', deleted: true);
    final pendingBefore = db.pendingCount;
    expect(
      () => attachments.add(
        nodeId: pageId,
        filename: 'orange.png',
        mimeType: 'image/png',
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
      throwsA(isA<AttachmentException>()),
    );
    expect(db.pendingCount, pendingBefore);
    expect(attachments.pendingUploads(), isEmpty);
  });

  testWidgets('an open page deleted elsewhere offers no attach button',
      (tester) async {
    final id = nodes.save(title: 'Doomed thrice', body: 'scans');
    await openEditor(tester, id);
    expect(find.text('Attach files'), findsOneWidget);

    receiveRemoteEdit(id, 'scans', deleted: true);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Attach files'), findsNothing,
        reason: 'a file attached now would go into the deleted page');
    expect(find.textContaining('Restore the page'), findsOneWidget);
  });

  // "Answer shown" was a flag of the page, not of a card. When a sync took the
  // shown card away (deleted, or answered, on another device), the next card
  // appeared with its answer already visible, and the rating recorded no
  // recall at all.
  testWidgets('a card that replaces the shown one starts hidden',
      (tester) async {
    final cards = CardRepository(db);
    cards.save(front: 'Capital of France?', back: 'Paris');
    cards.save(front: 'Capital of Peru?', back: 'Lima');
    Widget study() => MaterialApp(
          home: StudyPage(
              key: const ValueKey('study'), db: db, cards: cards, nodes: nodes),
        );
    await tester.pumpWidget(study());
    await tester.tap(find.text('Show answer'));
    await tester.pumpAndSettle();
    expect(find.text('Show answer'), findsNothing);

    // Another device deletes the card on screen; the next sync rebuilds.
    final shown = cards.due().first;
    final row = db.raw.select(
        'SELECT created_at, created_by FROM cards WHERE id = ?',
        [shown.cardId]).first;
    final clock =
        formatClock(DateTime.now().toUtc().add(const Duration(seconds: 1)));
    db.applyDeltas([
      Delta(
        seq: 0,
        table: 'cards',
        recordId: shown.cardId,
        op: 'UPDATE',
        payload: {
          'id': shown.cardId,
          'node_id': '',
          'front': shown.front,
          'back': shown.back,
          'created_at': row['created_at'],
          'created_by': row['created_by'],
          'updated_at': clock,
          'updated_by': 'another-device-user',
          'is_deleted': 1,
        },
      ),
    ], db.cursor);
    await tester.pumpWidget(study());
    await tester.pumpAndSettle();

    final next = cards.due().first;
    expect(next.cardId, isNot(shown.cardId));
    expect(find.text(next.front), findsOneWidget);
    expect(find.text('Show answer'), findsOneWidget,
        reason: 'the next card arrived with its answer already shown');
    expect(find.text(next.back), findsNothing);
  });

  // Cards could be created but never edited or deleted, and an empty one was
  // accepted: a blank card sat in every device's queue for good.
  testWidgets('a card can be edited and deleted, and needs both sides',
      (tester) async {
    final cards = CardRepository(db);
    final id = cards.save(nodeId: 'some-page', front: 'Tpyo?', back: 'x');
    cards.save(id: id, front: 'Typo?', back: 'fixed');
    final row = db.raw.select(
        'SELECT node_id, front, back FROM cards WHERE id = ?', [id]).first;
    expect(row['front'], 'Typo?');
    expect(row['node_id'], 'some-page',
        reason: 'editing the text detached the card from its page');

    final pendingBefore = db.pendingCount;
    cards.delete(id);
    expect(cards.due().where((c) => c.cardId == id), isEmpty);
    expect(db.pendingCount, pendingBefore + 1,
        reason: 'the deletion was not queued for sync');

    await tester.pumpWidget(MaterialApp(
      home: StudyPage(db: db, cards: cards, nodes: nodes),
    ));
    await tester.tap(find.byTooltip('New card'));
    await tester.pumpAndSettle();
    final create = find.widgetWithText(FilledButton, 'Create');
    expect(tester.widget<FilledButton>(create).onPressed, isNull,
        reason: 'an empty card could be created');
    await tester.enterText(find.byType(TextField).at(0), 'Front only');
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
    await tester.enterText(find.byType(TextField).at(1), 'and back');
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  // A card written in a page used to be edited as a row of its own on the
  // Study page, and the next edit of its line in the page undid that.
  testWidgets('a card from a page is edited and deleted through its line',
      (tester) async {
    final cards = CardRepository(db);
    final id = nodes.save(
      title: 'Africa',
      body: 'Capitals:\n\n- Capital of Niger :: Niamey\n'
          '- Capital of Togo :: Lome\n',
    );
    final cardId = pageCardId(id, 'capital of niger');
    DueCard niger() =>
        cards.due(limit: 1000).firstWhere((c) => c.cardId == cardId);
    // Answered long ago, so due before every other card in this database.
    cards.review(niger(), Rating.good, at: DateTime.utc(2000));

    await tester.pumpWidget(MaterialApp(
      home: StudyPage(db: db, cards: cards, nodes: nodes),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Capital of Niger'), findsOneWidget);
    expect(find.text('From "Africa"'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit card'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Saved to its line in "Africa"'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).at(1), 'Niamey, on the Niger');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(nodes.byId(id)!.body,
        contains('- Capital of Niger :: Niamey, on the Niger\n'),
        reason: 'the page does not say what the card says');
    expect(niger().back, 'Niamey, on the Niger');
    expect(niger().state.reps, 1, reason: 'the edit lost the schedule');

    await tester.tap(find.byTooltip('Delete card'));
    await tester.pumpAndSettle();
    expect(find.textContaining('its line in "Africa"'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    final body = nodes.byId(id)!.body;
    expect(body, isNot(contains('Niger')));
    expect(body, contains('- Capital of Togo :: Lome'));
    expect(cards.due(limit: 1000).where((c) => c.cardId == cardId), isEmpty);
  });

  // Saving an edited card wrote into its tombstone when it had been deleted
  // on another device meanwhile: the edit synced everywhere and showed
  // nowhere.
  testWidgets('a card deleted elsewhere while being edited stays deleted',
      (tester) async {
    final cards = CardRepository(db);
    Future<void> editWhileDeleted(String front, void Function() delete) async {
      // A fresh app each time: the first message would otherwise still be
      // showing, and hold back the second.
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        home: StudyPage(db: db, cards: cards, nodes: nodes),
      ));
      await tester.pumpAndSettle();
      expect(find.text(front), findsOneWidget);
      await tester.tap(find.byTooltip('Edit card'));
      await tester.pumpAndSettle();
      delete();
      await tester.enterText(find.byType(TextField).at(1), 'too late');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
    }

    // A card of its own.
    final own = cards.save(front: 'Gone soon?', back: 'yes');
    // Answered long ago, so it is the first card the Study page shows.
    cards.review(
        cards.due(limit: 1000).firstWhere((c) => c.cardId == own), Rating.good,
        at: DateTime.utc(1999));
    await editWhileDeleted('Gone soon?', () => cards.delete(own));
    expect(find.textContaining('deleted on another device'), findsOneWidget);
    final row = db.raw
        .select('SELECT back, is_deleted FROM cards WHERE id = ?', [own]).first;
    expect(row['is_deleted'], 1);
    expect(row['back'], 'yes', reason: 'the edit went into the tombstone');
    expect(find.text('Gone soon?'), findsNothing);

    // A card written in a page whose page goes.
    final page = nodes.save(title: 'Doomed', body: 'Doomed question :: yes');
    final fromPage = pageCardId(page, 'doomed question');
    cards.review(cards.due(limit: 1000).firstWhere((c) => c.cardId == fromPage),
        Rating.good,
        at: DateTime.utc(1999));
    await editWhileDeleted('Doomed question', () => nodes.delete(page));
    expect(find.textContaining('"Doomed" was deleted on another device'),
        findsOneWidget);
    expect(nodes.byId(page), isNull, reason: 'the edit restored the page');

    // Deleting a card that is gone already leaves its tombstone alone.
    final twice = cards.save(front: 'Twice?', back: 'once');
    expect(cards.delete(twice), isTrue);
    final pending = db.pendingCount;
    expect(cards.delete(twice), isFalse);
    expect(db.pendingCount, pending,
        reason: 'deleting a deleted card queued a write');
  // A second page with a title that is taken was saved without a word, and
  // every [[link]] to that title kept leading to the first one.
  testWidgets('saving a title that is taken asks first', (tester) async {
    final first = nodes.save(title: 'Twin', body: 'the first');
    Future<void> saveAs(String title) async {
      await tester.enterText(find.byType(TextField).at(0), title);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
    }

    // A new page.
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      home: NodeEditor(db: db, nodes: nodes, nodeId: null),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'Zwillingsseite');
    await saveAs('twin ');
    expect(find.text('"Twin" exists already'), findsOneWidget);
    await tester.tap(find.text('Change the title'));
    await tester.pumpAndSettle();
    expect(nodes.search('Zwillingsseite'), isEmpty,
        reason: 'the page was saved although the user chose to rename it');
    await saveAs('Twin, the other');
    expect(find.textContaining('exists already'), findsNothing);
    expect(nodes.byTitle('Twin, the other'), isNotNull);

    // A rename onto the taken title asks too; once the user chose to save
    // anyway, saving again does not ask again.
    await saveAs('Twin');
    expect(find.text('"Twin" exists already'), findsOneWidget);
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    expect(nodes.byTitle('Twin')!.id, first);
    await tester.enterText(
        find.byType(TextField).at(1), 'Zwillingsseite bearbeitet');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('exists already'), findsNothing);
    expect(nodes.search('bearbeitet'), isNotEmpty);
  });

  testWidgets('text fields have an accessible name', (tester) async {
    // Flutter renders InputDecoration's label as a sibling node, so without
    // explicit semantics the editable element reaches assistive technology
    // unnamed -- "edit text" and nothing else.
    //
    // The editor is pumped directly rather than navigated to: this is a claim
    // about the fields, and routing through the shell would make it a test of
    // the shell's animations too.
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);

    await tester.pumpWidget(MaterialApp(
      home: NodeEditor(db: db, nodes: nodes, nodeId: null),
    ));
    await tester.pumpAndSettle();

    for (final label in ['Title', 'Body']) {
      expect(
        find.bySemanticsLabel(label),
        findsWidgets,
        reason: 'the $label field announces nothing to a screen reader',
      );
    }
  });

  testWidgets('a fresh device offers its own origin as the server', (
    tester,
  ) async {
    // No server is stored yet: these phases sync through the API client, not
    // through the settings page. The app was served by a web server, so that
    // server is the default -- typing its URL by hand was the first hurdle
    // on every new account.
    expect(db.meta(MetaKeys.serverUrl), isNull);
    await tester.pumpWidget(MaterialApp(home: SettingsPage(db: db)));
    await tester.pumpAndSettle();

    expect(Uri.base.origin, startsWith('http'));
    expect(find.text(Uri.base.origin), findsOneWidget);
    // Offered, not stored: nothing is saved until the user acts.
    expect(db.meta(MetaKeys.serverUrl), isNull);
  });

  testWidgets('the history lists every version and restores an older one', (
    tester,
  ) async {
    const id = 'e2e-node-history';
    await syncAsOtherDevice(mutations: [
      nodeMutation(
        clientSeq: 1,
        id: id,
        title: 'History',
        body: 'first draft',
        clock: clockBefore(const Duration(minutes: 30)),
        op: 'INSERT',
      ),
      nodeMutation(
        clientSeq: 2,
        id: id,
        title: 'History',
        body: 'second draft',
        clock: clockBefore(const Duration(minutes: 20)),
      ),
    ]);

    PageVersion? restored;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            restored = await Navigator.of(context).push<PageVersion>(
              MaterialPageRoute(
                builder: (_) => HistoryPage(
                  load: () => api.history('nodes', id),
                  shown:
                      const PageVersion(title: 'History', body: 'second draft'),
                ),
              ),
            );
          },
          child: const Text('open history'),
        ),
      ),
    ));
    await tester.tap(find.text('open history'));
    // The history comes over the network; pumpAndSettle alone would return
    // while the request is still in flight.
    for (var i = 0; i < 50 && find.byType(ListTile).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.textContaining('(latest)'), findsOneWidget);
    expect(find.textContaining('Created by'), findsOneWidget);

    // The latest version is what the editor already shows: nothing to
    // restore.
    expect(find.textContaining('shown in the editor'), findsOneWidget);
    await tester.tap(find.textContaining('(latest)'));
    await tester.pumpAndSettle();
    expect(find.text('Restore this version'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Created by'));
    await tester.pumpAndSettle();
    expect(find.textContaining('first draft'), findsWidgets);
    await tester.tap(find.text('Restore this version'));
    await tester.pumpAndSettle();

    expect(restored?.title, 'History');
    expect(restored?.body, 'first draft');
  });

  testWidgets('search finds saved and synced pages, but not deleted ones', (
    _,
  ) async {
    nodes.save(title: 'Zettelkasten', body: 'slips of paper, linked by hand');
    final now = DateTime.now().toUtc();
    final stamp = formatClock(now);
    // A tombstone must be newer than the page, or Last-Write-Wins drops it.
    final later = formatClock(now.add(const Duration(seconds: 1)));
    Delta arriving({int deleted = 0}) => Delta(
          seq: 0,
          table: 'nodes',
          recordId: 'synced-searchable',
          op: 'UPDATE',
          payload: {
            'id': 'synced-searchable',
            'title': 'Mnemonic Major System',
            'title_key': 'mnemonic major system',
            'body': 'digits become consonants',
            'created_at': stamp,
            'created_by': 'another-device-user',
            'updated_at': deleted == 1 ? later : stamp,
            'updated_by': 'another-device-user',
            'is_deleted': deleted,
          },
        );
    db.applyDeltas([arriving()], db.cursor);

    List<String> titles(String query) =>
        nodes.search(query).map((hit) => hit.title).toList();
    expect(titles('zettel'), ['Zettelkasten']);
    expect(titles('paper linked'), ['Zettelkasten']);
    expect(titles('consonant'), ['Mnemonic Major System'],
        reason: 'a page that arrived by sync is not searchable');
    expect(titles('AND "('), isEmpty, reason: 'FTS5 syntax must not throw');

    // An upgraded device indexes the pages it already had, once.
    db.raw.execute("INSERT INTO nodes_fts (nodes_fts) VALUES ('delete-all')");
    db.raw.execute(
        'DELETE FROM sync_meta WHERE key = ?', [searchIndexVersionKey]);
    try {
      expect(titles('zettel'), isEmpty);
      expect(ensureSearchIndex(db.raw), isTrue);
      expect(ensureSearchIndex(db.raw), isFalse);
      expect(titles('zettel'), ['Zettelkasten']);
    } finally {
      // The index is shared with every later phase: never leave it empty.
      db.raw.execute("INSERT INTO nodes_fts (nodes_fts) VALUES ('rebuild')");
    }

    db.applyDeltas([arriving(deleted: 1)], db.cursor);
    expect(titles('consonant'), isEmpty,
        reason: 'a page deleted elsewhere is still found');
  });

  testWidgets('typing in the search field lists matching pages', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: WikiPage(db: db, nodes: nodes)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zettel');
    await tester.pumpAndSettle();

    expect(find.text('Zettelkasten'), findsOneWidget);
    expect(find.textContaining('slips of paper'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'no such words anywhere');
    await tester.pumpAndSettle();
    expect(find.text('No page matches.'), findsOneWidget);
  });

  testWidgets('an existing page opens rendered, and its links lead on', (
    tester,
  ) async {
    final id = nodes.save(
      title: 'Rendered',
      body: '# Heading\n\nSome **bold** text and a link to '
          '[[Rendered Target|the target]].\n\n`[[Not A Link]]`',
    );
    await tester.pumpWidget(MaterialApp(
      home: NodeEditor(db: db, nodes: nodes, nodeId: id),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing,
        reason: 'an existing page should open for reading');
    expect(find.text('Heading'), findsOneWidget);
    expect(find.textContaining('**bold**'), findsNothing);
    expect(nodes.byTitle('rendered target'), isNull);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.tap(find.byTooltip('Read'));
    await tester.pumpAndSettle();

    // Following a link to a page that does not exist yet creates it, as the
    // "Links out" list always did.
    await tester.tapOnText(find.textRange.ofSubstring('the target'));
    await tester.pumpAndSettle();
    expect(nodes.byTitle('rendered target'), isNotNull);
    expect(find.text('Rendered Target'), findsWidgets);
  });

  testWidgets('a question :: answer line in a page becomes a card', (_) async {
    final cards = CardRepository(db);
    List<String> due() => [
          for (final card in cards.due(limit: 1000))
            '${card.front} :: ${card.back}'
        ];

    final id = nodes.save(
      title: 'Geography',
      body: 'Some notes.\n\n- Capital of Burkina Faso :: Ouagadougou\n',
    );
    expect(due(), contains('Capital of Burkina Faso :: Ouagadougou'));

    // The card syncs like any other: another device studies it too.
    await sync.syncOnce();
    final cardId = pageCardId(id, 'capital of burkina faso');
    final trail = await history('cards', cardId);
    expect(trail, isNotEmpty, reason: 'the card never reached the server');
    expect(
        (trail.last['payload'] as Map<String, Object?>)['back'], 'Ouagadougou');

    // Fixing the answer keeps the card (and its schedule); removing the line
    // removes it.
    nodes.save(
        id: id,
        title: 'Geography',
        body: 'Capital of Burkina Faso :: Ouagadougou!');
    expect(due(), contains('Capital of Burkina Faso :: Ouagadougou!'));
    expect(due(), isNot(contains('Capital of Burkina Faso :: Ouagadougou')));
    nodes.save(id: id, title: 'Geography', body: 'No cards any more.');
    expect(
        due().where((c) => c.startsWith('Capital of Burkina Faso')), isEmpty);
  });

  testWidgets('deleting a page asks first and can be undone', (tester) async {
    final cards = CardRepository(db);
    bool hasCard() =>
        cards.due(limit: 1000).any((c) => c.front == 'Capital of Mali');
    final id = nodes.save(title: 'Doomed', body: 'Capital of Mali :: Bamako');
    // An answer fixed on the Study page: Undo must bring back this one, not
    // the page's text again.
    final cardId = pageCardId(id, 'capital of mali');
    cards.save(id: cardId, front: 'Capital of Mali', back: 'Bamako!');

    // The editor is pushed from somewhere, as in the app: deleting pops it.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => NodeEditor(db: db, nodes: nodes, nodeId: id))),
            child: const Text('Open the page'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open the page'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Its flashcard is deleted with it'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(nodes.byId(id), isNotNull, reason: 'Cancel deleted the page');

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(nodes.byId(id), isNull);
    expect(hasCard(), isFalse);
    expect(find.text('Open the page'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(nodes.byId(id)?.body, 'Capital of Mali :: Bamako',
        reason: 'Undo did not bring the page back');
    expect(hasCard(), isTrue, reason: 'Undo did not bring the card back');
    expect(cards.due(limit: 1000).firstWhere((c) => c.cardId == cardId).back,
        'Bamako!',
        reason: 'Undo rewrote the card from the page text');

    // A late Undo, after the page changed again, does nothing.
    final deletedAt = nodes.delete(id);
    nodes.save(id: id, title: 'Doomed', body: 'Written again');
    expect(nodes.undoDelete(id, deletedAt), isFalse);
    expect(nodes.byId(id)?.body, 'Written again');
  });

  testWidgets('wanted pages list the links to missing pages', (tester) async {
    nodes.save(title: 'Ferries', body: 'to [[zanzibar notes]]');
    nodes.save(
      title: 'Islands',
      body: 'See [[Zanzibar Notes]] and [[Pemba Island]]; '
          '`[[Not Wanted]]` is code.',
    );
    final wanted = {for (final page in nodes.wanted()) page.title: page};
    expect(wanted['Zanzibar Notes']?.linkedFrom,
        unorderedEquals(['Ferries', 'Islands']));
    expect(wanted['Pemba Island']?.linkedFrom, ['Islands']);
    expect(
        wanted.keys.map((t) => t.toLowerCase()), isNot(contains('not wanted')));

    await tester.pumpWidget(MaterialApp(home: WikiPage(db: db, nodes: nodes)));
    await tester.tap(find.text('Wanted'));
    await tester.pumpAndSettle();
    // The list, not the search field, which scrolls too.
    await tester.scrollUntilVisible(find.text('Zanzibar Notes'), 200,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Zanzibar Notes'));
    await tester.pumpAndSettle();
    expect(nodes.byTitle('zanzibar notes')?.title, 'Zanzibar Notes',
        reason: 'tapping a wanted page did not create it');
    expect(
        nodes.wanted().map((p) => p.title), isNot(contains('Zanzibar Notes')));
  });

  testWidgets('the app shell builds against the real local database', (
    tester,
  ) async {
    await tester.pumpWidget(GikiApp(db: db));
    await tester.pumpAndSettle();

    expect(find.text('giki'), findsOneWidget);
    expect(find.text('Wiki'), findsOneWidget);
    expect(find.text('Study'), findsOneWidget);
    // The page that survived the earlier phases is there. Found through the
    // search field: the list is built lazily, and the earlier phases have
    // added enough pages to push it below the fold.
    await tester.enterText(find.byType(TextField), 'Spaced Repetition');
    await tester.pumpAndSettle();
    expect(find.text('Spaced Repetition'), findsWidgets,
        reason: 'field: '
            '"${tester.widget<TextField>(find.byType(TextField)).controller?.text}", '
            'page: ${nodes.byTitle('spaced repetition')?.id}, '
            'hits: ${nodes.search('Spaced Repetition').map((h) => h.title).toList()}, '
            'focus: ${FocusManager.instance.primaryFocus}');
  });

  testWidgets('Ctrl+K jumps to the search, Ctrl+S saves', (tester) async {
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(GikiApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Study'));
    await tester.pumpAndSettle();
    await press(LogicalKeyboardKey.keyK);
    final search = tester.widget<TextField>(find.byType(TextField));
    expect(search.decoration?.hintText, 'Search pages');
    expect(search.focusNode?.hasFocus, isTrue,
        reason: 'Ctrl+K did not focus the search field');

    final id = nodes.save(title: 'Shortcut', body: 'before');
    await openEditor(tester, id);
    await tester.enterText(find.byType(TextField).at(1), 'after');
    await press(LogicalKeyboardKey.keyS);
    expect(nodes.byId(id)!.body, 'after', reason: 'Ctrl+S did not save');
  });

  // Last on purpose: it leaves this client's clock an hour ahead of the real
  // one, which "the other device writes in the past" phases above rely on not
  // being the case.
  testWidgets('an edit after pulling a fast clock still wins', (_) async {
    // The other device's clock runs an hour fast. Its edit reaches the
    // server and then this device...
    final ahead =
        formatClock(DateTime.now().toUtc().add(const Duration(hours: 1)));
    const id = 'e2e-node-fast-clock';
    await syncAsOtherDevice(mutations: [
      nodeMutation(
          clientSeq: 50,
          id: id,
          op: 'INSERT',
          title: 'Fast Clock',
          body: 'from the fast device',
          clock: ahead),
    ]);
    await sync.syncOnce();
    expect(nodes.byId(id)?.body, 'from the fast device');

    // ...and the user edits it here a moment later. With the wall clock this
    // edit was older than the version it replaced: the server called it
    // stale, the outbox dropped it, and this device kept text nobody else
    // would ever see.
    nodes.save(id: id, title: 'Fast Clock', body: 'edited after pulling');
    expect(nodes.byId(id)!.updatedAt.compareTo(ahead), greaterThan(0));
    final report = await sync.syncOnce();
    expect(report.applied, 1, reason: report.toString());
    expect(report.stale, 0, reason: report.toString());
    expect((await latestServerPayload(id))['body'], 'edited after pulling');
  });
}

/// Passkey phases.
///
/// What is checked here is the *contract* between the server's WebAuthn
/// options and the client code that converts them for the browser API: the
/// field names, the encodings, the shape. That is where the two sides drift
/// apart in practice.
///
/// What is not checked is a complete ceremony. That needs a virtual
/// authenticator, which is driven over the DevTools protocol from outside the
/// page -- unreachable from a test running inside it. The ceremonies
/// themselves are covered against a real software authenticator in
/// internal/syncapi/authapi_test.go.
void passkeyTests({
  required Uri Function() baseUrl,
  required String Function() registerToken,
}) {
  testWidgets('the server offers a login ceremony this client can digest', (
    _,
  ) async {
    final response = await http.post(
      baseUrl().resolve('api/v1/auth/passkey/login/begin'),
      headers: {'Content-Type': 'application/json'},
    );
    expect(response.statusCode, 200, reason: response.body);

    final body = jsonDecode(response.body) as Map<String, Object?>;
    expect(body['ceremony_id'], isA<String>());
    final options = body['options']! as Map<String, Object?>;

    // The real conversion, on the real server output, in a real browser.
    final prepared = prepareRequestOptions(options);
    expect(prepared['challenge'], isA<Uint8List>());
    expect(
      (prepared['challenge']! as Uint8List).length,
      greaterThanOrEqualTo(16),
      reason: 'a WebAuthn challenge must be at least 16 bytes',
    );
    expect(prepared['rpId'], 'localhost');
    expect(
      prepared.containsKey('allowCredentials'),
      isFalse,
      reason: 'a usernameless login must not restrict credentials',
    );
  });

  testWidgets(
      'the server offers a registration ceremony this client can digest', (
    _,
  ) async {
    final response = await http.post(
      baseUrl().resolve('api/v1/auth/passkey/register/begin'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${registerToken()}',
      },
      body: jsonEncode(
          {'user_id': 'passkey-user', 'display_name': 'Passkey User'}),
    );
    expect(response.statusCode, 200, reason: response.body);

    final body = jsonDecode(response.body) as Map<String, Object?>;
    final options = body['options']! as Map<String, Object?>;
    final prepared = prepareCreationOptions(options);

    expect(prepared['challenge'], isA<Uint8List>());
    final user = prepared['user']! as Map<String, Object?>;
    expect(user['id'], isA<Uint8List>());
    expect(
      (user['id']! as Uint8List).length,
      lessThanOrEqualTo(64),
      reason: 'a WebAuthn user handle is at most 64 bytes',
    );
    expect(user['name'], 'passkey-user');
    expect((prepared['rp']! as Map)['id'], 'localhost');

    // A resident key is what makes the usernameless login above possible.
    final selection =
        prepared['authenticatorSelection']! as Map<String, Object?>;
    expect(selection['residentKey'], 'required');
  });

  testWidgets('registration without the token is refused', (_) async {
    final response = await http.post(
      baseUrl().resolve('api/v1/auth/passkey/register/begin'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'user_id': 'intruder'}),
    );
    expect(response.statusCode, 401, reason: response.body);
  });

  testWidgets('the browser offers the WebAuthn API at all', (_) async {
    // http://localhost is a secure context, so this must hold in CI. If it
    // ever fails, passkeys are unavailable for a reason worth knowing about
    // rather than a flaky test.
    expect(passkeysAvailable, isTrue);
  });
}
