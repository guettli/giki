/// UUID generation for giki.
///
/// Every primary key in the system is a UUID minted by whichever device
/// created the row. That is what makes offline writes possible at all: an
/// AUTOINCREMENT id would collide the moment two devices insert while
/// disconnected, and the collision would only surface at sync time, when it is
/// far too late to fix.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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
  return _format(bytes);
}

/// A name-based id: the same namespace and parts always give the same UUID.
///
/// For rows that must be unique per combination of other values, like the one
/// review schedule per card and user. Two offline devices that each create
/// "the schedule for this card" then create the *same* row, and
/// Last-Write-Wins merges their versions. With random ids they created two
/// rows that nothing ever merged, and the card never left the study queue.
///
/// A version 8 (custom) UUID per RFC 9562, from SHA-256 of the namespace and
/// the parts, separated by NUL so that ("a", "bc") and ("ab", "c") differ.
String nameBasedId(String namespace, List<String> parts) {
  final digest =
      sha256.convert(utf8.encode([namespace, ...parts].join('\u0000'))).bytes;
  final bytes = Uint8List.fromList(digest.sublist(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x80; // version 8
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  return _format(bytes);
}

/// The id of the card written as a `question :: answer` line on page
/// [nodeId]; [key] is the question's cardKey. Every device computes the same
/// one, so the card a page produces is one row, wherever it was saved.
String pageCardId(String nodeId, String key) =>
    nameBasedId('giki/page_card', [nodeId, key]);

/// The id of [userId]'s review schedule for [cardId]. Every device computes
/// the same one.
String srsStateId(String cardId, String userId) =>
    nameBasedId('giki/srs_state', [cardId, userId]);

String _format(List<int> bytes) {
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
