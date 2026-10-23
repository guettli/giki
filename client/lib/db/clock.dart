/// giki's timestamp format, shared with the Go server (store.TimeFormat) and
/// the SQLite triggers (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')).
///
/// ISO-8601, UTC, exactly three decimals -- chosen so that comparing two of
/// these as plain strings is comparing two points in time. Last-Write-Wins
/// depends on that property in Dart, in Go and inside SQL alike.
library;

/// Formats [time] as a giki timestamp.
String formatClock(DateTime time) {
  final utc = time.toUtc();
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(utc.year, 4)}-${pad(utc.month, 2)}-${pad(utc.day, 2)}'
      'T${pad(utc.hour, 2)}:${pad(utc.minute, 2)}:${pad(utc.second, 2)}'
      '.${pad(utc.millisecond, 3)}Z';
}

/// The current time as a giki timestamp.
String nowClock() => formatClock(DateTime.now());

/// Parses a giki (or any ISO-8601) timestamp.
DateTime parseClock(String clock) => DateTime.parse(clock).toUtc();
