/// Files and images attached to wiki pages.
///
/// Two halves, synced differently. The `attachments` row (which page, which
/// file name, which hash) is ordinary synced data: outbox, Last-Write-Wins,
/// ChangeLog. The bytes are a content-addressed blob in the local `blobs`
/// table, which the sync worker uploads and fetches by SHA-256 on its own --
/// see SyncService.syncOnce for the order that keeps the two consistent.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'database.dart';
import 'ids.dart';

/// The largest file giki accepts. Must match MaxBlobBytes in
/// internal/syncapi/blobs.go: a larger blob would be refused on upload, and
/// the sync worker would retry it forever.
const int maxAttachmentBytes = 10 << 20;

/// Image types the app renders itself. Everything else, SVG included, is a
/// plain file to download: an SVG can carry script.
const Set<String> inlineImageTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/bmp',
};

/// Raised when a file cannot be attached.
class AttachmentException implements Exception {
  AttachmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One file attached to a page.
class Attachment {
  const Attachment({
    required this.id,
    required this.nodeId,
    required this.sha256,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.hasBytes,
  });

  final String id;
  final String nodeId;
  final String sha256;
  final String filename;
  final String mimeType;
  final int size;

  /// False while the bytes are still on the server only: the row arrived by
  /// sync and the blob has not been fetched yet.
  final bool hasBytes;

  /// True for images the app shows inline.
  bool get isImage => inlineImageTypes.contains(mimeType);
}

/// Hex SHA-256 of [bytes], the blob's key.
String blobKey(List<int> bytes) => sha256.convert(bytes).toString();

/// Attachment storage.
class AttachmentRepository {
  AttachmentRepository(this._db);

  final GikiDatabase _db;

  /// Attaches a file to [nodeId] and returns the new attachment's id.
  ///
  /// Blob and row are written in one transaction: a row without local bytes
  /// would be pushed, and other devices would wait for a blob nobody uploads.
  String add({
    required String nodeId,
    required String filename,
    required String mimeType,
    required Uint8List bytes,
  }) {
    if (bytes.length > maxAttachmentBytes) {
      throw AttachmentException(
          '$filename is ${_mib(bytes.length)}; the limit is '
          '${_mib(maxAttachmentBytes)}.');
    }
    // The page may have been deleted on another device since the editor
    // opened. A row pointing at the tombstone syncs everywhere and is shown
    // nowhere.
    final live = _db.raw.select(
        'SELECT 1 FROM nodes WHERE id = ? AND is_deleted = 0', [nodeId]);
    if (live.isEmpty) {
      throw AttachmentException(
          '$filename was not attached: the page was deleted on another '
          'device.');
    }
    final key = blobKey(bytes);
    final id = newId();
    final now = _db.now();
    final raw = _db.raw;
    raw.execute('BEGIN IMMEDIATE');
    try {
      raw.execute(
        'INSERT INTO blobs (sha256, size, data, uploaded, created_at) '
        'VALUES (?, ?, ?, 0, ?) ON CONFLICT (sha256) DO NOTHING',
        [key, bytes.length, bytes, now],
      );
      raw.execute(
        'INSERT INTO attachments (id, node_id, sha256, filename, mime_type, '
        '  size, created_at, created_by, updated_at, updated_by, is_deleted) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
        [
          id,
          nodeId,
          key,
          filename,
          mimeType,
          bytes.length,
          now,
          _db.userId,
          now,
          _db.userId,
        ],
      );
      raw.execute('COMMIT');
    } on Object {
      raw.execute('ROLLBACK');
      rethrow;
    }
    return id;
  }

  /// The live attachments of [nodeId], oldest first.
  List<Attachment> forNode(String nodeId) {
    final rows = _db.raw.select(
      'SELECT a.id, a.node_id, a.sha256, a.filename, a.mime_type, a.size, '
      '       b.sha256 IS NOT NULL AS has_bytes '
      'FROM attachments a LEFT JOIN blobs b ON b.sha256 = a.sha256 '
      'WHERE a.node_id = ? AND a.is_deleted = 0 '
      'ORDER BY a.created_at, a.id',
      [nodeId],
    );
    return [
      for (final row in rows)
        Attachment(
          id: row['id'] as String,
          nodeId: row['node_id'] as String,
          sha256: row['sha256'] as String,
          filename: row['filename'] as String,
          mimeType: row['mime_type'] as String,
          size: row['size'] as int,
          hasBytes: (row['has_bytes'] as int) == 1,
        ),
    ];
  }

  /// Tombstones an attachment. The blob stays: another attachment may share
  /// it, and an offline device may still be about to restore the row.
  void delete(String id) {
    final now = _db.now();
    _db.raw.execute(
      'UPDATE attachments SET is_deleted = 1, updated_at = ?, updated_by = ? '
      'WHERE id = ?',
      [now, _db.userId, id],
    );
  }

  /// The bytes of blob [key], or null if this device does not have them.
  Uint8List? bytes(String key) {
    final rows =
        _db.raw.select('SELECT data FROM blobs WHERE sha256 = ?', [key]);
    return rows.isEmpty ? null : rows.first['data'] as Uint8List;
  }

  // --- for the sync worker -------------------------------------------------

  /// Blobs added on this device that the server does not have yet.
  List<String> pendingUploads() => [
        for (final row in _db.raw
            .select('SELECT sha256 FROM blobs WHERE uploaded = 0 ORDER BY 1'))
          row['sha256'] as String,
      ];

  /// Records that the server confirmed it stores blob [key].
  void markUploaded(String key) =>
      _db.raw.execute('UPDATE blobs SET uploaded = 1 WHERE sha256 = ?', [key]);

  /// Those of [keys] this device has no bytes for.
  List<String> missing(Iterable<String> keys) => [
        for (final key in keys)
          if (_db.raw
              .select('SELECT 1 FROM blobs WHERE sha256 = ?', [key]).isEmpty)
            key,
      ];

  /// Stores bytes fetched from the server, after checking they are what the
  /// key says. Returns false, storing nothing, if they are not.
  bool storeFetched(String key, Uint8List bytes) {
    if (blobKey(bytes) != key) {
      return false;
    }
    _db.raw.execute(
      'INSERT INTO blobs (sha256, size, data, uploaded, created_at) '
      'VALUES (?, ?, ?, 1, ?) ON CONFLICT (sha256) DO NOTHING',
      [key, bytes.length, bytes, _db.now()],
    );
    return true;
  }
}

String _mib(int bytes) => '${(bytes / (1 << 20)).toStringAsFixed(1)} MiB';

/// The browser leaves File.type empty for extensions it does not know; fall
/// back to the extension for the types giki treats specially.
String guessMimeType(String filename, String reported) {
  if (reported.isNotEmpty) {
    return reported;
  }
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'pdf' => 'application/pdf',
    'txt' || 'md' => 'text/plain',
    _ => 'application/octet-stream',
  };
}

/// "1.4 MiB", "312 KiB", "18 B".
String formatSize(int bytes) {
  if (bytes >= 1 << 20) {
    return _mib(bytes);
  }
  if (bytes >= 1 << 10) {
    return '${(bytes / (1 << 10)).round()} KiB';
  }
  return '$bytes B';
}
