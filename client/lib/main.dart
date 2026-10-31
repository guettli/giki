/// giki -- local-first wiki and spaced repetition.
///
/// The app opens the local database first and shows the UI immediately; the
/// server is contacted afterwards, by the background worker, and never blocks
/// a read or a write.
library;

import 'package:flutter/material.dart';

import 'db/database.dart';
import 'db/tab_lock.dart';
import 'pages/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before opening: a second tab must not even read the database into
  // memory, or its first write would overwrite the first tab's.
  await holdDatabaseLock(GikiDatabase.defaultStorageName,
      onWaiting: () => runApp(const OpenElsewhere()));
  final db = await GikiDatabase.open();
  runApp(GikiApp(db: db));
}

/// Shown while giki is open in another tab or window. The app starts here
/// by itself once that one is closed.
class OpenElsewhere extends StatelessWidget {
  const OpenElsewhere({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'giki',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'giki is open in another tab or window. Close it there, and '
              'giki starts here.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// The application root.
class GikiApp extends StatelessWidget {
  const GikiApp({required this.db, super.key});

  /// The already-opened local database.
  final GikiDatabase db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'giki',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomePage(db: db),
    );
  }
}
