import 'package:flutter_test/flutter_test.dart';
import 'package:giki/pages/age.dart';

void main() {
  test('describes ages in words, and old ones by date', () {
    final now = DateTime(2026, 10, 30, 15, 0);
    String age(Duration ago) => describeAge(now.subtract(ago), now);
    expect(age(const Duration(seconds: 20)), 'just now');
    expect(age(const Duration(minutes: 1)), '1 minute ago');
    expect(age(const Duration(minutes: 59)), '59 minutes ago');
    expect(age(const Duration(hours: 1)), '1 hour ago');
    expect(age(const Duration(hours: 14)), '14 hours ago');
    expect(age(const Duration(hours: 16)), 'yesterday');
    expect(age(const Duration(days: 3)), '3 days ago');
    expect(describeAge(DateTime(2026, 9, 2, 8), now), '2026-09-02');
  });

  test('a clock running behind is "just now", not the future', () {
    final now = DateTime(2026, 10, 30, 15, 0);
    expect(describeAge(now.add(const Duration(minutes: 3)), now), 'just now');
  });
}
