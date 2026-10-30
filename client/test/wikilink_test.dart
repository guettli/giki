import 'package:flutter_test/flutter_test.dart';
import 'package:giki/wiki/wikilink.dart';

// Which links a body contains is tested in test_vm/wikilink_test.dart, which
// reads the cases it shares with the Go server from disk.
void main() {
  test('normalizes titles', () {
    expect(normalizeTitle('  Spaced   Repetition '), 'spaced repetition');
    expect(normalizeTitle('Leitner'), 'leitner');
    expect(normalizeTitle(''), '');
    expect(normalizeTitle('\tTabbed\nTitle'), 'tabbed title');
  });
}
