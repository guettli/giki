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

/// The clock for a write: the current time, but always later than every
/// clock this device has issued or seen.
///
/// A plain wall clock is not enough for Last-Write-Wins. A device whose clock
/// is behind another's -- or that stepped back after an NTP correction --
/// would stamp its edit of a page older than the version it just pulled. The
/// server keeps the stored row, the device keeps its own text, and the two
/// never meet again: the device has already received the winner and will not
/// be sent it twice. Bumping past every clock seen (a hybrid logical clock)
/// makes an edit win over everything its author could see when making it.
String nowClock() {
  var clock = formatClock(DateTime.now());
  if (clock.compareTo(_latest) <= 0) {
    clock =
        formatClock(parseClock(_latest).add(const Duration(milliseconds: 1)));
  }
  return _latest = clock;
}

/// Notes a clock seen in a row or from the server, so the next [nowClock]
/// is later. Anything that is not a giki timestamp is ignored: one garbage
/// string would otherwise compare above every real clock forever.
void observeClock(String? clock) {
  if (clock != null &&
      _canonical.hasMatch(clock) &&
      clock.compareTo(_latest) > 0) {
    _latest = clock;
  }
}

String _latest = '';

final _canonical = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$');

/// Parses a giki (or any ISO-8601) timestamp.
DateTime parseClock(String clock) => DateTime.parse(clock).toUtc();
