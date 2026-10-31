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

/// Notes a clock seen in a row, so the next [nowClock] is later.
///
/// Ignored: anything that is not a giki timestamp, since one garbage string
/// would compare above every real clock forever; and a clock more than
/// [maxClockLead] ahead of the real time, as best this device knows it.
/// Following a device whose clock says 2099 would drag every device's
/// writes, reviews and "edited ... ago" into 2099 with it, for good.
void observeClock(String? clock) {
  if (clock == null || !_canonical.hasMatch(clock)) {
    return;
  }
  final limit = formatClock(DateTime.now().add(_serverLead).add(maxClockLead));
  if (clock.compareTo(_latest) > 0 && clock.compareTo(limit) <= 0) {
    _latest = clock;
  }
}

/// Notes the server's time. It is followed like a row's clock, and it also
/// corrects this device's idea of the real time for [observeClock] -- a
/// device whose own clock is a day behind would otherwise ignore every
/// ordinary clock as too far ahead.
void observeServerClock(String? clock) {
  if (clock == null || !_canonical.hasMatch(clock)) {
    return;
  }
  final lead = parseClock(clock).difference(DateTime.now());
  _serverLead = lead.isNegative ? Duration.zero : lead;
  observeClock(clock);
}

/// How far ahead of the real time a clock may be and still be followed.
const maxClockLead = Duration(days: 1);

String _latest = '';
Duration _serverLead = Duration.zero;

final _canonical = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$');

/// Parses a giki (or any ISO-8601) timestamp.
DateTime parseClock(String clock) => DateTime.parse(clock).toUtc();
