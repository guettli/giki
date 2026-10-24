import 'package:flutter_test/flutter_test.dart';
import 'package:giki/db/ids.dart';

/// Reads the 48-bit millisecond timestamp back out of a UUIDv7.
int timestampOf(String id) =>
    int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16);

void main() {
  test('generates well-formed UUIDv7 values', () {
    final id = newId();
    expect(
        id,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('does not repeat', () {
    final ids = {for (var i = 0; i < 1000; i++) newId()};
    expect(ids, hasLength(1000));
  });

  // The test that matters. Comparing two ids minted milliseconds apart -- the
  // test below -- cannot see a timestamp that has lost its top bits: the low 32
  // bits still increase over a few milliseconds. Decoding the prefix and
  // comparing it with the clock can. On the web the old encoding produced
  // 0x00006c89230b for a moment in 2026, which reads as 1970-01-22.
  test('carries the current time in its prefix', () {
    final before = DateTime.now().millisecondsSinceEpoch;
    final stamp = timestampOf(newId());
    final after = DateTime.now().millisecondsSinceEpoch;
    expect(stamp, inInclusiveRange(before, after),
        reason:
            'the UUIDv7 timestamp is ${DateTime.fromMillisecondsSinceEpoch(stamp, isUtc: true)}');
  });

  test('encodes a timestamp above 2^32 exactly', () {
    // A fixed moment in 2026, chosen to exceed 32 bits -- the case that the
    // web's 32-bit shift semantics get wrong.
    expect(encodeTimestamp48(1792822369722), [1, 161, 108, 138, 93, 186]);
  });

  test('sorts by creation time, which keeps inserts sequential', () async {
    final first = newId();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = newId();
    expect(first.compareTo(second), lessThan(0));
  });
}
