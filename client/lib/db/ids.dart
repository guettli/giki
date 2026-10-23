/// UUID generation for giki.
///
/// Every primary key in the system is a UUID minted by whichever device
/// created the row. That is what makes offline writes possible at all: an
/// AUTOINCREMENT id would collide the moment two devices insert while
/// disconnected, and the collision would only surface at sync time, when it is
/// far too late to fix.
library;

import 'dart:math';
import 'dart:typed_data';

final Random _random = Random.secure();

/// Generates a UUIDv7: 48 bits of Unix milliseconds followed by randomness.
///
/// v7 rather than v4 because the timestamp prefix makes ids sort by creation
/// time, which keeps SQLite's B-tree inserts near-sequential and makes a debug
/// dump of the outbox readable in the order things happened.
String newId() {
  final bytes = Uint8List(16);
  final millis = DateTime.now().toUtc().millisecondsSinceEpoch;
  for (var i = 0; i < 6; i++) {
    bytes[i] = (millis >> (8 * (5 - i))) & 0xff;
  }
  for (var i = 6; i < 16; i++) {
    bytes[i] = _random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
