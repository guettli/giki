/// Platform-neutral data types shared by the local database and the sync
/// client.
///
/// They live apart from database.dart on purpose: that file imports the
/// SQLite-Wasm bindings and therefore only compiles for the web, while these
/// types -- and the code that parses the sync protocol -- are plain Dart and
/// can be unit-tested on the VM.
library;

/// Keys stored in the sync_meta table. sync_meta is local-only and never
/// synced: it describes this device, not the knowledge base.
class MetaKeys {
  /// The highest ChangeLog seq already written locally.
  static const String cursor = 'last_sync_cursor';

  /// This device's stable id. Generated once, on first launch.
  static const String deviceId = 'device_id';

  /// The user whose writes this device records.
  static const String userId = 'user_id';

  /// Base URL of the giki server, e.g. https://giki.example.org.
  static const String serverUrl = 'server_url';

  /// Bearer token for that server.
  static const String token = 'token';
}

/// One drained row of sync_outbox, ready to be pushed.
class OutboxEntry {
  const OutboxEntry({
    required this.seq,
    required this.table,
    required this.recordId,
    required this.op,
    required this.payload,
    required this.updatedAt,
  });

  /// Local outbox sequence. Echoed back by the server as `client_seq` so each
  /// row can be acknowledged individually.
  final int seq;
  final String table;
  final String recordId;
  final String op;

  /// The row as JSON, exactly as the SQLite trigger built it.
  final String payload;
  final String updatedAt;
}

/// A delta received from the server.
class Delta {
  const Delta({
    required this.seq,
    required this.table,
    required this.recordId,
    required this.op,
    required this.payload,
  });

  final int seq;
  final String table;
  final String recordId;
  final String op;

  /// The row as a decoded JSON object: column name to value.
  final Map<String, Object?> payload;
}

/// The tables that participate in sync. Mirrors the Go registry in
/// internal/store/registry.go.
const Set<String> syncableTables = {
  'users',
  'nodes',
  'cards',
  'srs_state',
  'review_log',
};
