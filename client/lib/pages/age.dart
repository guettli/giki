/// How long ago something happened, in words.
library;

/// [then] relative to [now]: "just now", "5 minutes ago", "yesterday", and
/// past a week the date itself, which says more than "23 days ago".
String describeAge(DateTime then, DateTime now) {
  final age = now.difference(then);
  if (age.inMinutes < 1) {
    return 'just now';
  }
  if (age.inHours < 1) {
    return _ago(age.inMinutes, 'minute');
  }
  final local = then.toLocal();
  final today = now.toLocal();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(local.year, local.month, local.day))
      .inDays;
  if (days == 0) {
    return _ago(age.inHours, 'hour');
  }
  if (days == 1) {
    return 'yesterday';
  }
  if (days < 7) {
    return '$days days ago';
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

String _ago(int n, String unit) => n == 1 ? '1 $unit ago' : '$n ${unit}s ago';
