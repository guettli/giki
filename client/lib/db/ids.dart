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
  bytes.setRange(
      0, 6, encodeTimestamp48(DateTime.now().toUtc().millisecondsSinceEpoch));
  for (var i = 6; i < 16; i++) {
    bytes[i] = _random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The 48-bit big-endian millisecond timestamp at the front of a UUIDv7.
///
/// No shifts past 32 bits. On the Dart VM `millis >> 40` is fine, but on the
/// web -- the only place giki runs -- bitwise operators work on the value
/// truncated to 32 bits, so the top two bytes came out as zero: every id
/// minted in a browser carried a date in January 1970 and sorted by creation
/// time only until the low 32 bits wrapped, every 49.7 days. The VM tests
/// passed throughout.
///
/// Integer division and remainder are exact for any millisecond count below
/// 2^53 on both platforms, and each half then fits in 32 bits.
List<int> encodeTimestamp48(int millis) {
  final high = millis ~/ 0x100000000; // top 16 bits
  final low = millis % 0x100000000; // bottom 32 bits
  return [
    (high >> 8) & 0xff,
    high & 0xff,
    (low >> 24) & 0xff,
    (low >> 16) & 0xff,
    (low >> 8) & 0xff,
    low & 0xff,
  ];
}
