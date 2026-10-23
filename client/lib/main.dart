/// giki -- local-first wiki and spaced repetition.
///
/// The app opens the local database first and shows the UI immediately; the
/// server is contacted afterwards, by the background worker, and never blocks
/// a read or a write.
library;

import 'package:flutter/material.dart';

import 'db/database.dart';
import 'pages/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await GikiDatabase.open();
  runApp(GikiApp(db: db));
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
