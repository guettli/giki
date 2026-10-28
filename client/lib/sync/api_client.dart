/// The HTTP side of synchronization: one endpoint, JSON in, JSON out.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/passkey_api.dart' show normalizeBaseUrl;
import '../db/models.dart';

/// What the server made of one pushed mutation.
class MutationResult {
  const MutationResult(
      {required this.clientSeq, required this.status, required this.reason});

  /// The local sync_outbox.seq this result refers to.
  final int clientSeq;

  /// 'applied', 'stale' or 'rejected'.
  final String status;

  /// Why, for anything other than 'applied'.
  final String reason;

  /// True when the server stored this mutation.
  bool get applied => status == 'applied';

  /// True when Last-Write-Wins discarded it. Not an error: the winning
  /// version arrives as a delta.
  bool get stale => status == 'stale';

  /// True when the server refused it. Retrying unchanged cannot help.
  bool get rejected => status == 'rejected';
}

/// One sync round trip's answer.
class SyncResponse {
  const SyncResponse({
    required this.cursor,
    required this.results,
    required this.changes,
    required this.hasMore,
    required this.serverTime,
  });

  final int cursor;
  final List<MutationResult> results;
  final List<Delta> changes;
  final bool hasMore;
  final String serverTime;
}

/// One entry of a record's audit trail on the server.
class HistoryEntry {
  const HistoryEntry({
    required this.seq,
    required this.op,
    required this.payload,
    required this.actorUserId,
    required this.originDeviceId,
    required this.appliedAt,
  });

  final int seq;

  /// 'INSERT', 'UPDATE' or 'DELETE'.
  final String op;

  /// The row as it was written. A DELETE carries only the id.
  final Map<String, Object?> payload;

  /// Who made the change, from the server's authenticated session.
  final String actorUserId;
  final String originDeviceId;

  /// When the server accepted it (server clock, RFC 3339 UTC).
  final String appliedAt;

  /// True when this change removed the record: a DELETE, or an update that
  /// tombstoned it.
  bool get deletes =>
      op == 'DELETE' ||
      payload['is_deleted'] == 1 ||
      payload['is_deleted'] == true;
}

/// Raised when the server answers with a non-2xx status.
class SyncApiException implements Exception {
  SyncApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'giki server returned $statusCode: $message';
}

/// Talks to POST /api/v1/sync.
class SyncApiClient {
  SyncApiClient(
      {required Uri baseUrl, required this.token, http.Client? httpClient})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _http = httpClient ?? http.Client();

  /// The server's base URL, always ending in a slash; see normalizeBaseUrl.
  final Uri baseUrl;
  final String token;
  final http.Client _http;

  /// Pushes [mutations] and pulls everything after [cursor].
  Future<SyncResponse> sync({
    required String deviceId,
    required int cursor,
    required List<OutboxEntry> mutations,
    int? maxDeltas,
  }) async {
    final body = jsonEncode({
      'device_id': deviceId,
      'cursor': cursor,
      if (maxDeltas != null) 'max_deltas': maxDeltas,
      'mutations': [
        for (final entry in mutations)
          {
            'client_seq': entry.seq,
            'table': entry.table,
            'record_id': entry.recordId,
            'op': entry.op,
            'updated_at': entry.updatedAt,
            // The trigger already produced JSON. Decoding it here only to
            // re-encode it is the price of not hand-splicing strings; it also
            // means a malformed payload fails on this device rather than
            // somewhere in the server's parser.
            'payload': jsonDecode(entry.payload),
          },
      ],
    });

    final response = await _http.post(
      baseUrl.resolve('api/v1/sync'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw SyncApiException(response.statusCode, response.body);
    }
    return parseSyncResponse(response.body);
  }

  /// Reads the audit trail of one record, newest first.
  Future<List<HistoryEntry>> history(String table, String recordId) async {
    final response = await _http.get(
      baseUrl.resolveUri(Uri(
        path: 'api/v1/history',
        queryParameters: {'table': table, 'record_id': recordId},
      )),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw SyncApiException(response.statusCode, response.body);
    }
    return parseHistoryResponse(response.body);
  }

  /// Uploads attachment bytes under their SHA-256. Idempotent.
  Future<void> putBlob(String sha256, Uint8List bytes) async {
    _checkBlobKey(sha256);
    final response = await _http.put(
      baseUrl.resolve('api/v1/blobs/$sha256'),
      headers: {
        'Content-Type': 'application/octet-stream',
        'Authorization': 'Bearer $token',
      },
      body: bytes,
    );
    if (response.statusCode != 200) {
      throw SyncApiException(response.statusCode, response.body);
    }
  }

  /// Downloads attachment bytes. The caller verifies the hash.
  Future<Uint8List> getBlob(String sha256) async {
    _checkBlobKey(sha256);
    final response = await _http.get(
      baseUrl.resolve('api/v1/blobs/$sha256'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw SyncApiException(response.statusCode, response.body);
    }
    return response.bodyBytes;
  }

  /// The key comes from a synced row, so from another device: anything but
  /// a plain hash could steer the request at another path on this server.
  static void _checkBlobKey(String key) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'sha256', 'not a lowercase hex sha256');
    }
  }

  /// Releases the underlying HTTP client.
  void close() => _http.close();
}

/// Decodes a sync response body. Separate from the HTTP call so it can be
/// tested without a server.
SyncResponse parseSyncResponse(String body) {
  final decoded = jsonDecode(body) as Map<String, Object?>;
  return SyncResponse(
    cursor: decoded['cursor']! as int,
    hasMore: (decoded['has_more'] as bool?) ?? false,
    serverTime: (decoded['server_time'] as String?) ?? '',
    results: [
      for (final raw in (decoded['results'] as List<Object?>? ?? const []))
        if (raw is Map<String, Object?>)
          MutationResult(
            clientSeq: raw['client_seq']! as int,
            status: raw['status']! as String,
            reason: (raw['reason'] as String?) ?? '',
          ),
    ],
    changes: [
      for (final raw in (decoded['changes'] as List<Object?>? ?? const []))
        if (raw is Map<String, Object?>)
          Delta(
            seq: raw['seq']! as int,
            table: raw['table']! as String,
            recordId: raw['record_id']! as String,
            op: raw['op']! as String,
            payload: (raw['payload'] as Map<String, Object?>?) ?? const {},
          ),
    ],
  );
}

/// Decodes a history response body, newest entry first. The server sends the
/// trail oldest first, which is the right order for an audit log and the
/// wrong one for a person looking for yesterday's version.
List<HistoryEntry> parseHistoryResponse(String body) {
  final decoded = jsonDecode(body) as Map<String, Object?>;
  return [
    for (final raw in (decoded['history'] as List<Object?>? ?? const []))
      if (raw is Map<String, Object?>)
        HistoryEntry(
          seq: raw['seq']! as int,
          op: raw['op']! as String,
          payload: (raw['payload'] as Map<String, Object?>?) ?? const {},
          actorUserId: (raw['actor_user_id'] as String?) ?? '',
          originDeviceId: (raw['origin_device_id'] as String?) ?? '',
          appliedAt: (raw['applied_at'] as String?) ?? '',
        ),
  ].reversed.toList();
}
