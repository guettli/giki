/// One tab at a time per local database.
///
/// Each tab holds its own copy of the database in memory and writes it back
/// to IndexedDB whole blocks at a time. Two tabs open at once therefore
/// overwrite each other: a page saved in one was gone after the other one
/// saved anything -- before it ever reached the server, and from a device id
/// the server would not have sent it back to anyway.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Takes the exclusive lock on the database called [storageName], for as
/// long as this tab lives.
///
/// Completes at once when no other tab has it. Otherwise calls [onWaiting]
/// and completes when the other tab is closed.
///
/// Without the Web Locks API (an insecure context, or a very old browser)
/// it completes at once: the app works as before, unguarded.
Future<void> holdDatabaseLock(
  String storageName, {
  required void Function() onWaiting,
}) async {
  if (!web.window.navigator.has('locks')) {
    return;
  }
  final name = 'giki-database:$storageName';
  if (!await _request(name, ifAvailable: true)) {
    onWaiting();
    await _request(name, ifAvailable: false);
  }
}

/// Never completes: returned to the lock manager, it keeps the lock until
/// the tab goes away.
final _forever = Completer<JSAny?>();

/// Asks for the lock; completes with whether it was granted. With
/// [ifAvailable], a lock held elsewhere is answered with false at once
/// instead of a wait.
Future<bool> _request(String name, {required bool ifAvailable}) {
  final granted = Completer<bool>();
  JSPromise<JSAny?>? onGrant(web.Lock? lock) {
    granted.complete(lock != null);
    return lock == null ? null : _forever.future.toJS;
  }

  web.window.navigator.locks
      .request(
        name,
        web.LockOptions(mode: 'exclusive', ifAvailable: ifAvailable),
        onGrant.toJS,
      )
      .toDart
      .ignore();
  return granted.future;
}
