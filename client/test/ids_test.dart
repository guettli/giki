import 'package:flutter_test/flutter_test.dart';
import 'package:giki/db/ids.dart';

void main() {
  test('generates well-formed UUIDv7 values', () {
    final id = newId();
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('does not repeat', () {
    final ids = {for (var i = 0; i < 1000; i++) newId()};
    expect(ids, hasLength(1000));
  });

  test('sorts by creation time, which keeps inserts sequential', () async {
    final first = newId();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = newId();
    expect(first.compareTo(second), lessThan(0));
  });
}
