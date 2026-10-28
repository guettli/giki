/// The local database: SQLite compiled to WebAssembly, stored in the Origin
/// Private File System.
///
/// This file is web-only -- it is what makes giki local-first. The UI reads and
/// writes here and nowhere else; the network is a background detail that
/// reconciles this database with the server later.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

import 'clock.dart';
import 'ids.dart';
import 'link_index.dart';
import 'search.dart';
import 'models.dart';
import 'srs_merge.dart';

export 'models.dart';

/// The local giki database.
class GikiDatabase {
  GikiDatabase._(this.raw, this._fileSystem) {
    // SQLite's own update hook, rather than a notify() call at every write
    // site: the outbox is written by triggers, so the writes that matter are
    // the ones no Dart code performs. A count maintained by hand would be
    // correct only until the next repository method forgot to announce
    // itself -- which is exactly how the badge came to be wrong.
    _outboxWatch = raw.updates.listen((update) {
      switch (update.tableName) {
        case 'sync_outbox':
          refreshPendingCount();
        case 'nodes':
          // Fires for deltas as well as local writes: sync_mute silences the
          // outbox triggers, not SQLite's update hook. That is what lets an
          // open editor notice its page changed underneath it.
          nodesRevision.value++;
        case 'attachments' || 'blobs':
          // A file attached here or elsewhere, or its bytes arriving.
          attachmentsRevision.value++;
      }
    });
  }

  /// The underlying SQLite handle. Exposed so repositories can run their own
  /// statements instead of this class growing a method per query.
  final CommonDatabase raw;
  final VirtualFileSystem _fileSystem;
  late final StreamSubscription<SqliteUpdate> _outboxWatch;

  /// How many mutations are waiting to be pushed, as something the UI can
  /// listen to. The sync indicator is the only signal giki gives that work has
  /// not reached the server, so it has to follow the outbox rather than
  /// whatever the last rebuild happened to see.
  final ValueNotifier<int> pendingChanges = ValueNotifier<int>(0);

  /// Bumped whenever any row in `nodes` changes, locally or from a delta.
  /// Listeners re-read what they care about; the value itself means nothing.
  final ValueNotifier<int> nodesRevision = ValueNotifier<int>(0);

  /// Bumped whenever an attachment or a blob changes, so a page's file list
  /// follows uploads, deletions and bytes fetched in the background.
  final ValueNotifier<int> attachmentsRevision = ValueNotifier<int>(0);

  /// Blob hashes that an open page shows but this device does not have. The
  /// sync worker fetches them as soon as they are asked for; nothing else is
  /// downloaded, so a tab holds only the files someone actually looked at.
  final Set<String> wantedBlobs = {};

  /// Bumped when [wantedBlobs] grows, to wake the sync worker.
  final ValueNotifier<int> blobsWanted = ValueNotifier<int>(0);

  /// Asks for the bytes of [keys] to be fetched.
  void wantBlobs(Iterable<String> keys) {
    final before = wantedBlobs.length;
    wantedBlobs.addAll(keys);
    if (wantedBlobs.length != before) {
      blobsWanted.value++;
    }
  }

  /// Where the database lives inside the virtual file system. SimpleOpfsFileSystem
  /// can only persist a file called `/database`, so that name is not ours to
  /// choose when OPFS is in use.
  static const String _opfsPath = '/database';
  static const String _indexedDbPath = '/giki.sqlite';

  /// Opens (and on first launch creates) the local database.
  ///
  /// [wasmUrl] is served from the PWA's own origin; fetch it once with
  /// tool/fetch-sqlite-wasm.sh.
  ///
  /// [storageName] names the browser-side storage holding the database file.
  /// The default is what the app uses; the end-to-end test passes a fresh name
  /// per run so it starts from an empty database instead of whatever the last
  /// run left behind.
  static Future<GikiDatabase> open({
    String wasmUrl = 'sqlite3.wasm',
    String storageName = 'giki',
  }) async {
    // Relative to <base href>, like every other file of the app. Dart resolves
    // a relative URL against the page's address instead, so a reload on
    // /some/path fetched /some/sqlite3.wasm -- the HTML shell -- and the app
    // never started.
    final sqlite = await WasmSqlite3.loadFromUrl(
        Uri.parse(web.document.baseURI).resolve(wasmUrl));
    final (fileSystem, path) = await _openFileSystem(storageName);
    sqlite.registerVirtualFileSystem(fileSystem, makeDefault: true);

    final db = sqlite.open(path);
    // WAL needs shared memory that the browser VFS does not provide.
    db.execute('PRAGMA journal_mode = MEMORY;');
    db.execute('PRAGMA foreign_keys = OFF;');

    // The schema files are the same bytes the Go server applies.
    for (final asset in [
      'assets/db/schema.sql',
      'assets/db/schema_client.sql'
    ]) {
      db.execute(await rootBundle.loadString(asset));
    }

    final giki = GikiDatabase._(db, fileSystem);
    giki._ensureDeviceId();
    // Repairs the link index of a device upgraded from a version whose deltas
    // did not maintain it. A no-op on every later start.
    ensureLinkIndex(db);
    // Indexes the pages a device had before search existed. A no-op on every
    // later start.
    ensureSearchIndex(db);
    // Collapses review schedules duplicated by older versions, which used
    // random ids. Finding none is one indexed query.
    mergeDuplicateSchedules(db);
    giki.refreshPendingCount();
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
  static Future<(VirtualFileSystem, String)> _openFileSystem(
    String storageName,
  ) async {
    try {
      final opfs = await SimpleOpfsFileSystem.loadFromStorage(storageName);
      return (opfs, _opfsPath);
    } on Object {
      final indexedDb = await IndexedDbFileSystem.open(dbName: storageName);
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
  void close() {
    unawaited(_outboxWatch.cancel());
    pendingChanges.dispose();
    nodesRevision.dispose();
    attachmentsRevision.dispose();
    blobsWanted.dispose();
    raw.close();
  }

  /// Re-reads the outbox depth into [pendingChanges].
  void refreshPendingCount() => pendingChanges.value = pendingCount;

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
      stmt.close();
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

    // The link index is derived, so it is not in the delta; rebuild it here or
    // a page that arrives by sync never appears in anyone's backlinks.
    if (delta.table == 'nodes') {
      reindexLinks(raw, delta.recordId);
    }
  }

  /// Convenience for repositories: the current timestamp.
  String now() => nowClock();
}
