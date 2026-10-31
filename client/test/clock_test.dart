import 'package:flutter_test/flutter_test.dart';
import 'package:giki/db/clock.dart';

void main() {
  test('formats timestamps the way the server and the triggers do', () {
    expect(
      formatClock(DateTime.utc(2026, 10, 23, 10, 0, 0, 7)),
      '2026-10-23T10:00:00.007Z',
    );
    expect(
      formatClock(DateTime.utc(2026, 1, 2, 3, 4, 5, 60)),
      '2026-01-02T03:04:05.060Z',
    );
  });

  test('converts to UTC, so clocks in different zones stay comparable', () {
    final local = DateTime.utc(2026, 10, 23, 10).toLocal();
    expect(formatClock(local), '2026-10-23T10:00:00.000Z');
  });

  test('string order is time order -- what Last-Write-Wins relies on', () {
    final earlier = formatClock(DateTime.utc(2026, 10, 23, 9, 59, 59, 999));
    final later = formatClock(DateTime.utc(2026, 10, 23, 10));
    expect(earlier.compareTo(later), lessThan(0));
  });

  test('every write clock is later than the one before', () {
    final clocks = [for (var i = 0; i < 50; i++) nowClock()];
    for (var i = 1; i < clocks.length; i++) {
      expect(clocks[i].compareTo(clocks[i - 1]), greaterThan(0));
    }
  });

  test('a write clock is later than any clock seen', () {
    final ahead =
        formatClock(DateTime.now().toUtc().add(const Duration(days: 1)));
    observeClock(ahead);
    expect(nowClock().compareTo(ahead), greaterThan(0));
    // Something older does not pull it back.
    observeClock('2000-01-01T00:00:00.000Z');
    expect(nowClock().compareTo(ahead), greaterThan(0));
  });

  test('a clock that is not a giki timestamp is ignored', () {
    final before = nowClock();
    observeClock('zzzz');
    observeClock('');
    observeClock(null);
    final after = nowClock();
    expect(after.compareTo(before), greaterThan(0));
    expect(after.startsWith('z'), isFalse);
  });

  test('round trips', () {
    final now = DateTime.utc(2026, 10, 23, 10, 11, 12, 345);
    expect(parseClock(formatClock(now)), now);
  });
}
