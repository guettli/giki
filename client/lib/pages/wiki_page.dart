/// The wiki: a list of nodes, an editor, and the backlinks that make the
/// collection more than a pile of notes.
library;

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../db/repository.dart';
import '../wiki/wikilink.dart';
import 'attachments_section.dart';

/// Lists the most recently edited nodes.
class WikiPage extends StatefulWidget {
  const WikiPage({required this.db, required this.nodes, super.key});

  /// The local database.
  final GikiDatabase db;

  /// Node storage.
  final NodeRepository nodes;

  @override
  State<WikiPage> createState() => _WikiPageState();
}

class _WikiPageState extends State<WikiPage> {
  @override
  Widget build(BuildContext context) {
    final recent = widget.nodes.recent();
    return Scaffold(
      body: recent.isEmpty
          ? const Center(child: Text('No pages yet. Create one.'))
          : ListView.builder(
              itemCount: recent.length,
              itemBuilder: (context, index) {
                final node = recent[index];
                return ListTile(
                  title: Text(node.title.isEmpty ? '(untitled)' : node.title),
                  subtitle: Text(node.updatedAt),
                  onTap: () => _edit(node.id),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        tooltip: 'New page',
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _edit(String? id) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          NodeEditor(db: widget.db, nodes: widget.nodes, nodeId: id),
    ));
    if (mounted) {
      setState(() {});
    }
  }
}

/// Edits one node and shows what links to it.
class NodeEditor extends StatefulWidget {
  const NodeEditor({
    required this.db,
    required this.nodes,
    required this.nodeId,
    super.key,
  });

  /// The local database.
  final GikiDatabase db;

  /// Node storage.
  final NodeRepository nodes;

  /// The node to edit, or null to create one.
  final String? nodeId;

  @override
  State<NodeEditor> createState() => _NodeEditorState();
}

class _NodeEditorState extends State<NodeEditor> {
  late Node? _node =
      widget.nodeId == null ? null : widget.nodes.byId(widget.nodeId!);
  late final TextEditingController _title =
      TextEditingController(text: _node?.title ?? '');
  late final TextEditingController _body =
      TextEditingController(text: _node?.body ?? '');

  /// The version this editor's text is based on: what was loaded, or last
  /// saved. Comparing it with the stored row is how the editor notices that
  /// another device changed the page while it was open.
  String? get _baseVersion => _node?.updatedAt;

  /// The text as loaded or last saved, to tell "the user edited something"
  /// apart from "the user pressed Save".
  ///
  /// Assigned in initState, deliberately not with a `late` initializer: those
  /// run on first *access*, and the first access is in _dirty -- after the
  /// user has typed. That captured the typed text as "saved", so editing an
  /// existing page and pressing Save reported "No changes to save." and wrote
  /// nothing, and an incoming change silently replaced unsaved typing.
  late String _savedTitle;
  late String _savedBody;

  /// True when the stored page moved on while this editor had unsaved edits.
  bool _changedElsewhere = false;

  /// True when another device deleted the page while this editor had it open.
  /// The text stays, so the user can restore the page or copy what they typed.
  bool _deletedElsewhere = false;

  bool get _dirty =>
      _title.text.trim() != _savedTitle.trim() || _body.text != _savedBody;

  @override
  void initState() {
    super.initState();
    _savedTitle = _title.text;
    _savedBody = _body.text;
    widget.db.nodesRevision.addListener(_onNodesChanged);
  }

  @override
  void dispose() {
    widget.db.nodesRevision.removeListener(_onNodesChanged);
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// A row in `nodes` changed -- maybe this page, maybe from another device.
  void _onNodesChanged() {
    final node = _node;
    if (node == null || !mounted) {
      return;
    }
    final stored = widget.nodes.byId(node.id);
    if (stored == null) {
      if (!_deletedElsewhere) {
        setState(() => _deletedElsewhere = true);
      }
      return;
    }
    if (_deletedElsewhere) {
      // Restored elsewhere; from here on it is an ordinary newer version.
      setState(() => _deletedElsewhere = false);
    }
    if (stored.updatedAt == _baseVersion) {
      return;
    }
    if (_dirty) {
      // Keep what the user typed, but make sure Save cannot quietly overwrite
      // the newer version.
      setState(() => _changedElsewhere = true);
      return;
    }
    // Nothing unsaved: show the newer version rather than a stale one.
    setState(() => _adopt(stored));
  }

  void _adopt(Node node) {
    _node = node;
    _title.text = node.title;
    _body.text = node.body;
    _savedTitle = node.title;
    _savedBody = node.body;
    _changedElsewhere = false;
    _deletedElsewhere = false;
  }

  Future<void> _save() async {
    final existing = _node;

    // Nothing changed: write nothing. A save always stamps a fresh updated_at,
    // and under Last-Write-Wins a fresh timestamp on unchanged text beats any
    // newer edit another device made -- which is how pressing Save on a page
    // you never touched used to erase someone else's writing.
    // A page deleted elsewhere is the exception: Save then offers a restore.
    if (existing != null && !_dirty && widget.nodes.byId(existing.id) != null) {
      _snack('No changes to save.');
      return;
    }

    // Re-read rather than trusting _changedElsewhere: the update hook is
    // asynchronous, and a delta may have landed a moment ago.
    if (existing != null) {
      final stored = widget.nodes.byId(existing.id);
      if (stored == null) {
        // Deleted on another device. Saving would write into the tombstone:
        // "saved", yet invisible on every device. Ask instead.
        final restore = await _confirmRestore();
        if (!mounted) {
          return;
        }
        if (!restore) {
          Navigator.of(context).pop();
          return;
        }
      } else if (stored.updatedAt != _baseVersion) {
        final overwrite = await _confirmOverwrite();
        if (!mounted) {
          return;
        }
        if (!overwrite) {
          setState(() => _adopt(stored));
          _snack('Showing the version from the other device.');
          return;
        }
      }
    }

    final id = widget.nodes.save(
      id: existing?.id,
      title: _title.text.trim(),
      body: _body.text,
    );
    setState(() {
      _node = widget.nodes.byId(id);
      _savedTitle = _title.text;
      _savedBody = _body.text;
      _changedElsewhere = false;
      _deletedElsewhere = false;
    });
    _snack('Saved locally. It will sync in the background.');
  }

  Future<bool> _confirmOverwrite() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Changed on another device'),
        content: const Text(
          'This page was changed somewhere else after you opened it. '
          'Saving now replaces that version with yours.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Show their version'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Overwrite with mine'),
          ),
        ],
      ),
    );
    return choice ?? false;
  }

  Future<bool> _confirmRestore() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deleted on another device'),
        content: const Text(
          'This page was deleted somewhere else after you opened it. '
          'Saving restores it, with your text, on every device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Discard my text'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore with my text'),
          ),
        ],
      ),
    );
    return choice ?? false;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final node = _node;
    final backlinks = node == null
        ? const <NodeSummary>[]
        : widget.nodes.backlinks(node.titleKey);
    final targets = parseLinks(_body.text);

    return Scaffold(
      appBar: AppBar(
        title: Text(node == null ? 'New page' : 'Edit page'),
        actions: [
          if (node != null)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                widget.nodes.delete(node.id);
                Navigator.of(context).pop();
              },
            ),
          IconButton(
              tooltip: 'Save', icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_deletedElsewhere)
            MaterialBanner(
              content: const Text(
                'This page was deleted on another device. Your text is still '
                'here; saving restores the page.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            )
          else if (_changedElsewhere)
            MaterialBanner(
              content: const Text(
                'This page was changed on another device while you were '
                'editing. Saving will ask before replacing that version.',
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    final stored = widget.nodes.byId(_node!.id);
                    if (stored != null) {
                      setState(() => _adopt(stored));
                    }
                  },
                  child: const Text('Discard mine, show theirs'),
                ),
              ],
            ),
          // Semantics around every field: Flutter renders InputDecoration's
          // label as a separate node, so the editable element itself reaches
          // the browser's accessibility tree with no name at all -- a screen
          // reader announces "edit text" and nothing more.
          Semantics(
            textField: true,
            label: 'Title',
            child: TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            textField: true,
            label: 'Body',
            child: TextField(
              controller: _body,
              minLines: 8,
              maxLines: null,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Body',
                helperText: 'Link with [[Another Page]]. A link to a page that '
                    'does not exist yet is fine.',
              ),
            ),
          ),
          const SizedBox(height: 24),
          AttachmentsSection(db: widget.db, nodeId: node?.id),
          const SizedBox(height: 16),
          if (targets.isNotEmpty) ...[
            Text('Links out', style: Theme.of(context).textTheme.titleSmall),
            for (final target in targets)
              ListTile(
                dense: true,
                leading: Icon(
                  widget.nodes.byTitle(target) == null
                      ? Icons.add_circle_outline
                      : Icons.north_east,
                ),
                title: Text(target),
                subtitle: Text(widget.nodes.byTitle(target) == null
                    ? 'does not exist yet -- tap to create'
                    : 'open'),
                onTap: () => _follow(target),
              ),
            const SizedBox(height: 16),
          ],
          Text('Backlinks', style: Theme.of(context).textTheme.titleSmall),
          if (backlinks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Nothing links here yet.'),
            ),
          for (final source in backlinks)
            ListTile(
              dense: true,
              leading: const Icon(Icons.south_west),
              title: Text(source.title),
              onTap: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => NodeEditor(
                    db: widget.db,
                    nodes: widget.nodes,
                    nodeId: source.id,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Follows a [[link]], creating the target page if it does not exist yet.
  void _follow(String titleKey) {
    final existing = widget.nodes.byTitle(titleKey);
    final id = existing?.id ?? widget.nodes.save(title: titleKey, body: '');
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) =>
          NodeEditor(db: widget.db, nodes: widget.nodes, nodeId: id),
    ));
  }
}
