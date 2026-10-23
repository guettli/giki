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

  test('round trips', () {
    final now = DateTime.utc(2026, 10, 23, 10, 11, 12, 345);
    expect(parseClock(formatClock(now)), now);
  });
}
