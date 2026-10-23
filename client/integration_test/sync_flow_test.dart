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

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:giki/auth/webauthn.dart';
import 'package:giki/auth/webauthn_json.dart';
import 'package:giki/db/clock.dart';
import 'package:giki/db/database.dart';
import 'package:giki/db/repository.dart';
import 'package:giki/main.dart';
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

  testWidgets('the app shell builds against the real local database', (
    tester,
  ) async {
    await tester.pumpWidget(GikiApp(db: db));
    await tester.pumpAndSettle();

    expect(find.text('giki'), findsOneWidget);
    expect(find.text('Wiki'), findsOneWidget);
    expect(find.text('Study'), findsOneWidget);
    // The page that survived the earlier phases is listed.
    expect(find.text('Spaced Repetition'), findsWidgets);
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
