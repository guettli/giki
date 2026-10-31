/// The background sync worker.
///
/// It owns the whole protocol in one readable method, which is the "zero
/// magic" part of the design: there is no CRDT library, no hidden merge, and
/// nothing happens to the user's data that is not visible in syncOnce().
library;

import 'dart:async';
import 'dart:convert';

import '../db/attachments.dart';
import '../db/clock.dart';
import '../db/database.dart';
import 'api_client.dart';

/// What one sync round trip did.
class SyncReport {
  const SyncReport({
    required this.pushed,
    required this.applied,
    required this.stale,
    required this.rejected,
    required this.pulled,
    required this.cursor,
    required this.hasMore,
    this.uploaded = 0,
    this.fetched = 0,
  });

  /// An empty report, for "nothing to do".
  const SyncReport.idle(this.cursor)
      : pushed = 0,
        applied = 0,
        stale = 0,
        rejected = const [],
        pulled = 0,
        hasMore = false,
        uploaded = 0,
        fetched = 0;

  final int pushed;
  final int applied;
  final int stale;

  /// Mutations the server refused, with its reasons. These are bugs worth
  /// surfacing rather than retrying.
  final List<MutationResult> rejected;

  final int pulled;
  final int cursor;

  /// True when more deltas are waiting on the server.
  final bool hasMore;

  /// Attachment blobs sent to and received from the server.
  final int uploaded;
  final int fetched;

  @override
  String toString() => 'pushed $pushed (applied $applied, stale $stale, '
      'rejected ${rejected.length}), pulled $pulled, cursor $cursor'
      '${uploaded + fetched > 0 ? ', files up $uploaded down $fetched' : ''}';
}

/// Drains the outbox and applies deltas.
class SyncService {
  SyncService({
    required GikiDatabase db,
    required SyncApiClient api,
    this.batchSize = 500,
  })  : _db = db,
        _api = api,
        _attachments = AttachmentRepository(db) {
    _db.blobsWanted.addListener(_onBlobsWanted);
  }

  final GikiDatabase _db;
  final SyncApiClient _api;
  final AttachmentRepository _attachments;

  /// How many outbox rows go into one request.
  final int batchSize;

  Timer? _timer;
  bool _running = false;

  /// Fires after every successful round trip, so the UI can refresh.
  final StreamController<SyncReport> _reports =
      StreamController<SyncReport>.broadcast();

  /// Reports of completed round trips.
  Stream<SyncReport> get reports => _reports.stream;

  /// Starts periodic syncing. Safe to call twice.
  void start({Duration interval = const Duration(seconds: 30)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) async {
      try {
        await syncOnce();
      } on Object {
        // Offline is the normal case, not an error: the outbox keeps the
        // mutations and the next tick tries again.
      }
    });
  }

  /// Stops periodic syncing.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Releases resources.
  Future<void> dispose() async {
    stop();
    _db.blobsWanted.removeListener(_onBlobsWanted);
    await _reports.close();
  }

  void _onBlobsWanted() {
    unawaited(fetchWantedBlobs().catchError((Object _) => 0));
  }

  /// Downloads the blobs an open page asked for (GikiDatabase.wantBlobs).
  /// Returns how many arrived.
  ///
  /// Concurrent callers share one run, and that run keeps going until no
  /// wanted hash is left untried -- so a page that asks while a fetch is in
  /// flight is served by it rather than by the next round.
  ///
  /// A hash the server does not know is dropped from the wish list rather
  /// than asked for again on every round; opening the page asks again.
  Future<int> fetchWantedBlobs() =>
      _fetch ??= _fetchWanted().whenComplete(() => _fetch = null);

  Future<int>? _fetch;

  Future<int> _fetchWanted() async {
    var fetched = 0;
    final tried = <String>{};
    while (true) {
      _db.wantedBlobs.removeWhere((key) => _attachments.missing([key]).isEmpty);
      final next = _db.wantedBlobs.difference(tried);
      if (next.isEmpty) {
        break;
      }
      for (final key in next) {
        tried.add(key);
        try {
          if (_attachments.storeFetched(key, await _api.getBlob(key))) {
            fetched++;
          }
          _db.wantedBlobs.remove(key);
        } on SyncApiException catch (e) {
          if (e.statusCode == 404) {
            _db.wantedBlobs.remove(key);
          }
        } on ArgumentError {
          // Not a hash at all; no request is ever going to fetch it.
          _db.wantedBlobs.remove(key);
        } on Object {
          // Offline or a dropped connection: keep the wish, try next round.
          if (fetched > 0) {
            await _db.flush();
          }
          return fetched;
        }
      }
    }
    if (fetched > 0) {
      await _db.flush();
    }
    return fetched;
  }

  /// Runs one push-and-pull round trip.
  ///
  /// Overlapping runs are skipped rather than queued: two concurrent pushes of
  /// the same outbox rows would be applied twice on the server.
  Future<SyncReport> syncOnce() async {
    if (_running) {
      return SyncReport.idle(_db.cursor);
    }
    _running = true;
    try {
      // Read the outbox FIRST, then upload every pending blob. A row is
      // written in the same transaction as its blob, so every attachment row
      // in this read has its blob in the list that follows; the other order
      // would let a file attached mid-upload push its row ahead of its bytes.
      // (The server refuses such a row anyway, see apply.go.)
      final outbox = _db.readOutbox(limit: batchSize);

      // A blob that fails to upload holds back only the rows that point at
      // it; everything else -- text edits, reviews, other files -- syncs.
      final failed = <String>{};
      var uploaded = 0;
      for (final key in _attachments.pendingUploads()) {
        final bytes = _attachments.bytes(key);
        try {
          if (bytes != null) {
            await _api.putBlob(key, bytes);
          }
          _attachments.markUploaded(key);
          uploaded++;
        } on Object {
          // Refused, timed out on a slow link, or offline. If offline, the
          // sync call below fails too; otherwise the round goes on without
          // this file, and the next round uploads it again.
          failed.add(key);
        }
      }
      if (uploaded > 0) {
        await _db.flush();
      }
      final pending = [
        for (final entry in outbox)
          if (!_waitsForBlob(entry, failed)) entry,
      ];
      final response = await _api.sync(
        deviceId: _db.deviceId,
        cursor: _db.cursor,
        mutations: pending,
        maxDeltas: batchSize,
      );

      // Order matters. Deltas and the new cursor are committed first, in one
      // transaction. Only then are the pushed rows dropped from the outbox:
      // if the tab dies in between, those mutations are pushed again, and the
      // server's Last-Write-Wins makes the repeat a no-op. The reverse order
      // would lose them.
      // A device whose clock is behind the server's writes after it from
      // now on, so its next edit is not born stale.
      observeClock(response.serverTime);
      _db.applyDeltas(response.changes, response.cursor);
      await _db.flush();

      final settled = <int>[];
      var applied = 0;
      var stale = 0;
      final rejected = <MutationResult>[];
      for (final result in response.results) {
        if (result.applied) {
          applied++;
        } else if (result.stale) {
          stale++;
        } else {
          rejected.add(result);
        }
        // Rejected rows are dropped too: the server will never accept them as
        // they are, so keeping them would block the outbox forever.
        // TODO: move them to a local dead-letter table instead of only
        // reporting them, so a rejection can be inspected after a reload.
        settled.add(result.clientSeq);
      }
      _db.forgetOutbox(settled);
      await _db.flush();

      // Pages that are open may be waiting for bytes this round can bring.
      final fetched = await fetchWantedBlobs();

      final report = SyncReport(
        pushed: pending.length,
        applied: applied,
        stale: stale,
        rejected: rejected,
        pulled: response.changes.length,
        cursor: response.cursor,
        hasMore: response.hasMore,
        uploaded: uploaded,
        fetched: fetched,
      );
      if (!_reports.isClosed) {
        _reports.add(report);
      }
      return report;
    } finally {
      _running = false;
    }
  }

  /// Syncs until the server has nothing left, for a device that has been
  /// offline for a long time. [maxRounds] bounds the catch-up so a bug cannot
  /// turn it into an endless loop.
  Future<SyncReport> syncUntilCaughtUp({int maxRounds = 50}) async {
    var report = SyncReport.idle(_db.cursor);
    for (var round = 0; round < maxRounds; round++) {
      report = await syncOnce();
      if (!report.hasMore && report.pushed == 0) {
        break;
      }
      if (!report.hasMore && _db.pendingCount == 0) {
        break;
      }
    }
    return report;
  }

  /// True for an attachment row whose blob did not upload this round.
  static bool _waitsForBlob(OutboxEntry entry, Set<String> failed) {
    if (failed.isEmpty || entry.table != 'attachments') {
      return false;
    }
    final payload = jsonDecode(entry.payload) as Map<String, Object?>;
    return payload['is_deleted'] != 1 && failed.contains(payload['sha256']);
  }
}
