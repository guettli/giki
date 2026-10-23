/// The shell: wiki on one tab, study on the other, sync state in the app bar.
library;

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../db/repository.dart';
import '../sync/api_client.dart';
import '../sync/sync_service.dart';
import 'settings_page.dart';
import 'study_page.dart';
import 'wiki_page.dart';

/// Hosts the two main views and owns the sync service.
class HomePage extends StatefulWidget {
  const HomePage({required this.db, super.key});

  /// The local database.
  final GikiDatabase db;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  SyncService? _sync;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _configureSync();
  }

  @override
  void dispose() {
    _sync?.dispose();
    super.dispose();
  }

  /// Builds the sync service from the stored settings, if there are any. An
  /// unconfigured giki is still fully usable -- it is simply local-only.
  void _configureSync() {
    _sync?.dispose();
    _sync = null;
    final url = widget.db.meta(MetaKeys.serverUrl) ?? '';
    final token = widget.db.meta(MetaKeys.token) ?? '';
    if (url.isEmpty || token.isEmpty) {
      setState(() => _status = 'local only');
      return;
    }
    final service = SyncService(
      db: widget.db,
      api: SyncApiClient(baseUrl: Uri.parse(url), token: token),
    );
    service.reports.listen((report) {
      if (mounted) {
        setState(() => _status = 'synced: $report');
      }
    });
    service.start();
    setState(() {
      _sync = service;
      _status = 'sync every 30s';
    });
  }

  Future<void> _syncNow() async {
    final service = _sync;
    if (service == null) {
      setState(() => _status = 'no server configured');
      return;
    }
    setState(() => _status = 'syncing...');
    try {
      final report = await service.syncUntilCaughtUp();
      if (!mounted) return;
      setState(() => _status = report.rejected.isEmpty
          ? 'synced: $report'
          : 'synced with ${report.rejected.length} rejected: '
              '${report.rejected.first.reason}');
    } on SyncApiException catch (error) {
      if (!mounted) return;
      setState(() => _status = error.toString());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status = 'offline ($error)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.db.pendingCount;
    return Scaffold(
      appBar: AppBar(
        title: const Text('giki'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SettingsPage(db: widget.db),
              ));
              _configureSync();
            },
          ),
          IconButton(
            tooltip: pending == 0 ? 'Sync now' : '$pending change(s) waiting',
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.sync),
            ),
            onPressed: _syncNow,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_status, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          WikiPage(db: widget.db, nodes: NodeRepository(widget.db)),
          StudyPage(db: widget.db, cards: CardRepository(widget.db)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.account_tree), label: 'Wiki'),
          NavigationDestination(icon: Icon(Icons.school), label: 'Study'),
        ],
      ),
    );
  }
}
