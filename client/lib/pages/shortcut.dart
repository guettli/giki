/// Ctrl+key shortcuts that work wherever the focus is.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A key handler for Ctrl+[key] (Cmd+[key] on a Mac) that calls [onPressed]
/// while the route of [context] is the one on top. Register it with
/// HardwareKeyboard.instance.addHandler, and remove it in dispose.
///
/// Not CallbackShortcuts: those see a key only when the focused widget is
/// below them, and after a click on a tab or a button the focus is usually
/// above the screen's widgets, where the keys never reach them. A
/// HardwareKeyboard handler sees every key; checking the route keeps a
/// screen's shortcut from firing under a dialog or another screen.
KeyEventCallback controlShortcut(
  BuildContext Function() context,
  LogicalKeyboardKey key,
  VoidCallback onPressed,
) =>
    (event) {
      final keyboard = HardwareKeyboard.instance;
      if (event is! KeyDownEvent ||
          event.logicalKey != key ||
          !(keyboard.isControlPressed || keyboard.isMetaPressed) ||
          keyboard.isAltPressed ||
          keyboard.isShiftPressed) {
        return false;
      }
      final current = context();
      if (!current.mounted || !(ModalRoute.of(current)?.isCurrent ?? true)) {
        return false;
      }
      onPressed();
      // Handled: the browser does not also run its own Ctrl+S or Ctrl+K.
      return true;
    };
