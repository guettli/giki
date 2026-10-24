/// The background sync worker.
///
/// It owns the whole protocol in one readable method, which is the "zero
/// magic" part of the design: there is no CRDT library, no hidden merge, and
/// nothing happens to the user's data that is not visible in syncOnce().
library;

import 'dart:async';

import '../db/attachments.dart';
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
        _attachments = AttachmentRepository(db);

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
    await _reports.close();
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
      // Blobs before metadata. Once an attachment row reaches the server,
      // every other device will ask for its bytes, so they must be there
      // first. A failed upload aborts the round; the outbox waits for it.
      final uploads = _attachments.pendingUploads();
      for (final key in uploads) {
        final bytes = _attachments.bytes(key);
        if (bytes != null) {
          await _api.putBlob(key, bytes);
        }
        _attachments.markUploaded(key);
      }
      if (uploads.isNotEmpty) {
        await _db.flush();
      }

      final pending = _db.readOutbox(limit: batchSize);
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

      // Then the bytes of attachments that arrived, or that an earlier round
      // could not fetch. Best effort: a page shows "not downloaded yet" for a
      // missing blob, and the next round tries again.
      var fetched = 0;
      for (final key in _attachments.missingBlobs()) {
        try {
          if (_attachments.storeFetched(key, await _api.getBlob(key))) {
            fetched++;
          }
        } on Object {
          // Offline, or the server lost it. Either way, not this round.
        }
      }
      if (fetched > 0) {
        await _db.flush();
      }

      final report = SyncReport(
        pushed: pending.length,
        applied: applied,
        stale: stale,
        rejected: rejected,
        pulled: response.changes.length,
        cursor: response.cursor,
        hasMore: response.hasMore,
        uploaded: uploads.length,
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
}
