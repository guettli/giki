/// The local database: SQLite compiled to WebAssembly, stored in the Origin
/// Private File System.
///
/// This file is web-only -- it is what makes giki local-first. The UI reads and
/// writes here and nowhere else; the network is a background detail that
/// reconciles this database with the server later.
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:sqlite3/wasm.dart';

import 'clock.dart';
import 'ids.dart';
import 'models.dart';

export 'models.dart';

/// The local giki database.
class GikiDatabase {
  GikiDatabase._(this.raw, this._fileSystem);

  /// The underlying SQLite handle. Exposed so repositories can run their own
  /// statements instead of this class growing a method per query.
  final CommonDatabase raw;
  final VirtualFileSystem _fileSystem;

  /// Where the database lives inside the virtual file system. SimpleOpfsFileSystem
  /// can only persist a file called `/database`, so that name is not ours to
  /// choose when OPFS is in use.
  static const String _opfsPath = '/database';
  static const String _indexedDbPath = '/giki.sqlite';

  /// Opens (and on first launch creates) the local database.
  ///
  /// [wasmUrl] is served from the PWA's own origin; fetch it once with
  /// tool/fetch-sqlite-wasm.sh.
  static Future<GikiDatabase> open({String wasmUrl = 'sqlite3.wasm'}) async {
    final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse(wasmUrl));
    final (fileSystem, path) = await _openFileSystem();
    sqlite.registerVirtualFileSystem(fileSystem, makeDefault: true);

    final db = sqlite.open(path);
    // WAL needs shared memory that the browser VFS does not provide.
    db.execute('PRAGMA journal_mode = MEMORY;');
    db.execute('PRAGMA foreign_keys = OFF;');

    // The schema files are the same bytes the Go server applies.
    for (final asset in ['assets/db/schema.sql', 'assets/db/schema_client.sql']) {
      db.execute(await rootBundle.loadString(asset));
    }

    final giki = GikiDatabase._(db, fileSystem);
    giki._ensureDeviceId();
    await giki.flush();
    return giki;
  }

  /// Picks a virtual file system and the database path that goes with it.
  ///
  /// OPFS with synchronous access handles is the fast path, but it only works
  /// inside a dedicated web worker -- on the main thread the handles cannot be
  /// opened at all. Until the database is moved into a worker (see
  /// docs/architecture.md) this attempt fails in a normal tab and we fall back
  /// to the IndexedDB-backed file system, which is slower but correct and
  /// works everywhere.
  static Future<(VirtualFileSystem, String)> _openFileSystem() async {
    try {
      final opfs = await SimpleOpfsFileSystem.loadFromStorage('giki');
      return (opfs, _opfsPath);
    } on Object {
      final indexedDb = await IndexedDbFileSystem.open(dbName: 'giki');
      return (indexedDb, _indexedDbPath);
    }
  }

  /// Persists pending writes. A no-op on OPFS, where writes are synchronous.
  Future<void> flush() async {
    final fs = _fileSystem;
    if (fs is IndexedDbFileSystem) {
      await fs.flush();
    }
  }

  /// Closes the database.
  void close() => raw.dispose();

  // --- sync_meta -----------------------------------------------------------

  /// Reads a sync_meta value.
  String? meta(String key) {
    final rows = raw.select('SELECT value FROM sync_meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Writes a sync_meta value.
  void setMeta(String key, String value) {
    raw.execute(
      'INSERT INTO sync_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  /// This device's id, generated on first launch and stable afterwards.
  String get deviceId => meta(MetaKeys.deviceId)!;

  /// The current user id, or an empty string before sign-in.
  String get userId => meta(MetaKeys.userId) ?? '';

  /// The local sync cursor.
  int get cursor => int.tryParse(meta(MetaKeys.cursor) ?? '0') ?? 0;

  void _ensureDeviceId() {
    if (meta(MetaKeys.deviceId) == null) {
      setMeta(MetaKeys.deviceId, newId());
    }
  }

  // --- outbox --------------------------------------------------------------

  /// Reads up to [limit] pending mutations, oldest first.
  List<OutboxEntry> readOutbox({int limit = 500}) {
    final rows = raw.select(
      'SELECT seq, table_name, record_id, op, payload, updated_at '
      'FROM sync_outbox ORDER BY seq LIMIT ?',
      [limit],
    );
    return [
      for (final row in rows)
        OutboxEntry(
          seq: row['seq'] as int,
          table: row['table_name'] as String,
          recordId: row['record_id'] as String,
          op: row['op'] as String,
          payload: row['payload'] as String,
          updatedAt: row['updated_at'] as String,
        ),
    ];
  }

  /// Removes acknowledged mutations.
  ///
  /// Deletes by explicit sequence number rather than "everything up to the
  /// highest" -- the user keeps typing during a sync, and those newer rows
  /// have not been pushed yet.
  void forgetOutbox(Iterable<int> seqs) {
    final stmt = raw.prepare('DELETE FROM sync_outbox WHERE seq = ?');
    try {
      for (final seq in seqs) {
        stmt.execute([seq]);
      }
    } finally {
      stmt.dispose();
    }
  }

  /// How many mutations are waiting to be pushed.
  int get pendingCount =>
      raw.select('SELECT COUNT(*) AS n FROM sync_outbox').first['n'] as int;

  // --- deltas --------------------------------------------------------------

  /// Writes server deltas into the local database and advances the cursor.
  ///
  /// Everything happens in one transaction with a row in sync_mute, so the
  /// triggers do not write these incoming rows back into the outbox -- that
  /// echo would be sent to the server on the next sync, where it would arrive
  /// as a duplicate of a change the server already has.
  ///
  /// The cursor is advanced inside the same transaction as the rows it refers
  /// to. If the tab is closed mid-write, both roll back together and the same
  /// deltas arrive again.
  void applyDeltas(List<Delta> deltas, int cursor) {
    raw.execute('BEGIN IMMEDIATE');
    try {
      raw.execute("INSERT INTO sync_mute (token) VALUES ('applying-deltas')");
      for (final delta in deltas) {
        _applyDelta(delta);
      }
      raw.execute(
        'INSERT INTO sync_meta (key, value) VALUES (?, ?) '
        'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
        [MetaKeys.cursor, cursor.toString()],
      );
      raw.execute('DELETE FROM sync_mute');
      raw.execute('COMMIT');
    } on Object {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  void _applyDelta(Delta delta) {
    if (!syncableTables.contains(delta.table)) {
      // The server only ever sends tables this client knows; anything else
      // means the server is newer than the app. Skipping is the safe
      // behaviour, but the cursor still advances past it, so the row is only
      // picked up after a reload with a newer client.
      return;
    }
    final columns = delta.payload.keys.toList()..sort();
    if (columns.isEmpty) {
      return;
    }
    final placeholders = List.filled(columns.length, '?').join(', ');
    final assignments = columns
        .where((c) => c != 'id')
        .map((c) => '"$c" = excluded."$c"')
        .join(', ');
    final quoted = columns.map((c) => '"$c"').join(', ');

    // Last-Write-Wins again, this time locally: a delta must not overwrite a
    // local edit the user made while the request was in flight and which has
    // not been pushed yet.
    raw.execute(
      'INSERT INTO "${delta.table}" ($quoted) VALUES ($placeholders) '
      'ON CONFLICT (id) DO UPDATE SET $assignments '
      'WHERE excluded.updated_at > "${delta.table}".updated_at',
      [for (final column in columns) delta.payload[column]],
    );
  }

  /// Convenience for repositories: the current timestamp.
  String now() => nowClock();
}
