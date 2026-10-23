/// Server settings. Stored in sync_meta, which is local-only and never synced.
library;

import 'package:flutter/material.dart';

import '../db/database.dart';

/// Lets the user point this device at a giki server.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.db, super.key});

  /// The local database.
  final GikiDatabase db;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url =
      TextEditingController(text: widget.db.meta(MetaKeys.serverUrl) ?? '');
  late final TextEditingController _token =
      TextEditingController(text: widget.db.meta(MetaKeys.token) ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.db.meta(MetaKeys.userId) ?? '');

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _user.dispose();
    super.dispose();
  }

  void _save() {
    widget.db.setMeta(MetaKeys.serverUrl, _url.text.trim());
    widget.db.setMeta(MetaKeys.token, _token.text.trim());
    widget.db.setMeta(MetaKeys.userId, _user.text.trim());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://giki.example.org',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Bearer token'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            decoration: const InputDecoration(
              labelText: 'User id',
              helperText: 'Recorded as the author of your local changes.',
            ),
          ),
          const SizedBox(height: 24),
          Text('Device id: ${widget.db.deviceId}',
              style: Theme.of(context).textTheme.bodySmall),
          Text('Sync cursor: ${widget.db.cursor}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
