/// The wiki: a list of nodes, an editor, and the backlinks that make the
/// collection more than a pile of notes.
library;

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../db/repository.dart';
import '../wiki/wikilink.dart';

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

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final id = widget.nodes.save(
      id: _node?.id,
      title: _title.text.trim(),
      body: _body.text,
    );
    setState(() => _node = widget.nodes.byId(id));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Saved locally. It will sync in the background.')),
    );
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
