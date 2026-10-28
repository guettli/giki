/// A page's history as the server recorded it: who changed it, when, and to
/// what -- with a way back to any earlier version.
library;

import 'package:flutter/material.dart';

import '../sync/api_client.dart';

/// The title and body of an earlier version, handed back to the editor.
class PageVersion {
  const PageVersion({required this.title, required this.body});

  final String title;
  final String body;
}

/// Lists the server's ChangeLog for one page, newest first.
///
/// Pops with a [PageVersion] when the user chooses to restore one. Restoring
/// only fills the editor: the user still saves, so the usual "changed on
/// another device" checks apply and nothing is written by looking around.
class HistoryPage extends StatefulWidget {
  const HistoryPage({required this.load, this.shown, super.key});

  /// Fetches the history; a function so a test can stand in for the server.
  final Future<List<HistoryEntry>> Function() load;

  /// What the editor shows right now. A version with the same text has
  /// nothing to restore; any other can be restored -- including the server's
  /// newest one, when this device has unsynced edits or has not pulled yet.
  final PageVersion? shown;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<HistoryEntry>> _history = widget.load();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _history = widget.load()),
          ),
        ],
      ),
      body: FutureBuilder<List<HistoryEntry>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final error = snapshot.error;
          if (error is SyncApiException && error.statusCode == 401) {
            return const _Message(
              "The server did not accept this device's sign-in. Sign in "
              'again under Settings to see the history.',
            );
          }
          if (snapshot.hasError) {
            return const _Message(
              'The history lives on the server, which cannot be reached '
              'right now. Your pages are unaffected.',
            );
          }
          final history = snapshot.data!;
          if (history.isEmpty) {
            return const _Message(
              'No history on the server yet. Changes appear here once they '
              'have synced.',
            );
          }
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Newest first. Changes that have not synced yet are not '
                  'listed.',
                ),
              ),
              for (var i = 0; i < history.length; i++)
                _EntryTile(
                  entry: history[i],
                  current: i == 0,
                  shown: _isShown(history[i]),
                  onTap: () => _show(history[i]),
                ),
            ],
          );
        },
      ),
    );
  }

  /// True when [entry] holds exactly the text the editor shows.
  bool _isShown(HistoryEntry entry) {
    final version = _versionOf(entry);
    final shown = widget.shown;
    return version != null &&
        shown != null &&
        version.title.trim() == shown.title.trim() &&
        version.body == shown.body;
  }

  Future<void> _show(HistoryEntry entry) async {
    final version = _versionOf(entry);
    final shown = _isShown(entry);
    final restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_headline(entry)),
        content: SingleChildScrollView(
          child: version == null
              ? const Text('The page was deleted here; there is no text.')
              : SelectableText(
                  '${version.title}\n\n${version.body}'.trimRight(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
          if (version != null && !shown)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Restore this version'),
            ),
        ],
      ),
    );
    if ((restore ?? false) && mounted && version != null) {
      Navigator.of(context).pop(version);
    }
  }
}

/// The text of [entry], or null when it carries none (a deletion).
PageVersion? _versionOf(HistoryEntry entry) {
  if (entry.deletes) {
    return null;
  }
  final title = entry.payload['title'];
  final body = entry.payload['body'];
  if (title is! String || body is! String) {
    return null;
  }
  return PageVersion(title: title, body: body);
}

/// "Edited by alice", "Created by bob", ...
String _headline(HistoryEntry entry) {
  final who = entry.actorUserId.isEmpty ? 'someone' : entry.actorUserId;
  final what = entry.deletes
      ? 'Deleted'
      : entry.op == 'INSERT'
          ? 'Created'
          : 'Edited';
  return '$what by $who';
}

/// The server's UTC timestamp in this device's local time, to the minute.
String _when(String appliedAt) {
  final parsed = DateTime.tryParse(appliedAt);
  if (parsed == null) {
    return appliedAt;
  }
  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.current,
    required this.shown,
    required this.onTap,
  });

  final HistoryEntry entry;

  /// The server's newest entry.
  final bool current;

  /// The editor shows exactly this version's text.
  final bool shown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final version = _versionOf(entry);
    final preview =
        version == null ? '' : version.body.trim().split('\n').first;
    return ListTile(
      leading: Icon(
        entry.deletes
            ? Icons.delete_outline
            : entry.op == 'INSERT'
                ? Icons.add_circle_outline
                : Icons.edit_outlined,
      ),
      title: Text([
        _headline(entry),
        if (current) '(latest)',
        if (shown) '· shown in the editor',
      ].join(' ')),
      subtitle: Text(
        preview.isEmpty
            ? _when(entry.appliedAt)
            : '${_when(entry.appliedAt)} · $preview',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}
