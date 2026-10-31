@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:giki/db/tab_lock.dart';

void main() {
  test('a second holder waits until the first lets go', () async {
    final name = 'tab-lock-test-${DateTime.now().microsecondsSinceEpoch}';
    var waited = 0;

    await holdDatabaseLock(name, onWaiting: () => waited++);
    expect(waited, 0, reason: 'a free lock was not granted at once');

    // The first holder keeps the lock for good, as a tab does, so the
    // second one must still be waiting a while later.
    var granted = false;
    unawaited(holdDatabaseLock(name, onWaiting: () => waited++)
        .then((_) => granted = true));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(waited, 1);
    expect(granted, isFalse, reason: 'two holders had the lock at once');
  });
}
