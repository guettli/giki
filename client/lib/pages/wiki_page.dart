/// The wiki: a list of nodes, an editor, and the backlinks that make the
/// collection more than a pile of notes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../db/attachments.dart';
import '../db/clock.dart';

import '../db/database.dart';
import '../db/repository.dart';
import '../srs/card_text.dart';
import '../sync/api_client.dart';
import '../wiki/markdown_view.dart';
import '../wiki/snippet.dart';
import '../wiki/wikilink.dart';
import 'age.dart';
import 'attachments_section.dart';
import 'history_page.dart';

/// Lists the most recently edited nodes.
class WikiPage extends StatefulWidget {
  const WikiPage({
    required this.db,
    required this.nodes,
    this.searchFocus,
    super.key,
  });

  /// The local database.
  final GikiDatabase db;

  /// Node storage.
  final NodeRepository nodes;

  /// Focus of the search field, for the app's Ctrl+K.
  final FocusNode? searchFocus;

  @override
  State<WikiPage> createState() => _WikiPageState();
}

class _WikiPageState extends State<WikiPage> {
  final TextEditingController _query = TextEditingController();

  /// Lists the pages that are linked to but missing, instead of the recent.
  bool _wanted = false;

  @override
  void initState() {
    super.initState();
    // Pages that arrive by sync show up in the list and in the results
    // without the user having to retype.
    widget.db.nodesRevision.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.db.nodesRevision.removeListener(_refresh);
    _query.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.text.trim().isNotEmpty;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Semantics(
              textField: true,
              label: 'Search pages',
              child: TextField(
                controller: _query,
                focusNode: widget.searchFocus,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search pages',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(_query.clear),
                        )
                      : null,
                ),
              ),
            ),
          ),
          if (!searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      label: Text('Recent'),
                      icon: Icon(Icons.schedule)),
                  ButtonSegment(
                      value: true,
                      label: Text('Wanted'),
                      icon: Icon(Icons.add_link)),
                ],
                selected: {_wanted},
                onSelectionChanged: (choice) =>
                    setState(() => _wanted = choice.single),
              ),
            ),
          Expanded(
            child: searching
                ? _results()
                : _wanted
                    ? _wantedPages()
                    : _recent(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        tooltip: 'New page',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _recent() {
    final recent = widget.nodes.recent();
    final now = DateTime.now();
    if (recent.isEmpty) {
      return const Center(child: Text('No pages yet. Create one.'));
    }
    return ListView.builder(
      itemCount: recent.length,
      itemBuilder: (context, index) {
        final node = recent[index];
        return ListTile(
          title: Text(node.title.isEmpty ? '(untitled)' : node.title),
          subtitle: Text(describeAge(parseClock(node.updatedAt), now)),
          onTap: () => _edit(node.id),
        );
      },
    );
  }

  Widget _wantedPages() {
    final wanted = widget.nodes.wanted();
    if (wanted.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No wanted pages. A [[link]] to a page that does not '
              'exist yet shows up here.'),
        ),
      );
    }
    return ListView.builder(
      itemCount: wanted.length,
      itemBuilder: (context, index) {
        final page = wanted[index];
        final from = page.linkedFrom.map((t) => t.isEmpty ? '(untitled)' : t);
        return ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: Text(page.title),
          subtitle: Text('Linked from ${from.join(', ')}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          // As following the link does: the page is created, then opened.
          onTap: () => _edit(widget.nodes.byTitle(page.title)?.id ??
              widget.nodes.save(title: page.title, body: '')),
        );
      },
    );
  }

  Widget _results() {
    final hits = widget.nodes.search(_query.text);
    if (hits.isEmpty) {
      return const Center(child: Text('No page matches.'));
    }
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (context, index) {
        final hit = hits[index];
        return ListTile(
          title: Text(hit.title.isEmpty ? '(untitled)' : hit.title),
          subtitle: hit.snippet.trim().isEmpty
              ? null
              : Text.rich(
                  highlightSnippet(hit.snippet, Theme.of(context)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: () => _edit(hit.id),
        );
      },
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

  /// True while the page is shown rendered rather than as text fields. An
  /// existing page opens for reading; a new one opens for writing.
  late bool _reading = widget.nodeId != null;

  late final AttachmentRepository _attachments = AttachmentRepository(
    widget.db,
  );

  /// Decoded inline images by hash, kept across rebuilds: Image.memory treats
  /// every new Uint8List as a new picture and would decode it again.
  final Map<String, Uint8List> _images = {};

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
    widget.db.attachmentsRevision.addListener(_onAttachmentsChanged);
  }

  /// An attachment or its bytes arrived: an inline image may now be showable.
  void _onAttachmentsChanged() {
    if (mounted && _reading) {
      setState(() {});
    }
  }

  /// The bytes of this page's attachment called [filename], if this device
  /// has them. Missing bytes are fetched by the attachments section below,
  /// whose arrival rebuilds this view.
  Uint8List? _imageBytes(String filename) {
    final nodeId = _node?.id;
    if (nodeId == null) {
      return null;
    }
    for (final attachment in _attachments.forNode(nodeId)) {
      // The same allowlist as the attachments section: SVG and other
      // formats are offered for download, never rendered.
      if (attachment.filename == filename &&
          attachment.isImage &&
          attachment.hasBytes) {
        final cached = _images[attachment.sha256];
        if (cached != null) {
          return cached;
        }
        final bytes = _attachments.bytes(attachment.sha256);
        if (bytes != null) {
          _images[attachment.sha256] = bytes;
        }
        return bytes;
      }
    }
    return null;
  }

  void _openExternal(Uri uri) {
    // noopener: the opened page gets no handle on this one.
    web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  }

  @override
  void dispose() {
    widget.db.nodesRevision.removeListener(_onNodesChanged);
    widget.db.attachmentsRevision.removeListener(_onAttachmentsChanged);
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

  /// Deletes [shown] after asking, and offers to undo it for a while.
  ///
  /// A deleted page is a tombstone that syncs to every device, and it takes
  /// the cards its lines wrote with it. Undo takes back exactly this
  /// deletion (NodeRepository.undoDelete), and only while nothing else has
  /// happened to the page.
  Future<void> _delete(Node shown) async {
    final cards = parseCardLines(shown.body).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${shown.title}"?'),
        content: Text([
          'The page is deleted on all your devices.',
          if (cards == 1) 'Its flashcard is deleted with it.',
          if (cards > 1) 'Its $cards flashcards are deleted with it.',
          if (_dirty) 'Your unsaved changes are discarded.',
        ].join(' ')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final nodes = widget.nodes;
    // This page is about to close; the snack bar lives on in the app's
    // messenger, below whichever page is shown next.
    final messenger = ScaffoldMessenger.of(context);
    // Read after the dialog: a sync may have changed or deleted the page
    // while it was open.
    final node = nodes.byId(shown.id);
    Navigator.of(context).pop();
    messenger.hideCurrentSnackBar();
    if (node == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('The page was already deleted on another device.')));
      return;
    }
    final deletedAt = nodes.delete(node.id);
    messenger.showSnackBar(SnackBar(
      content: Text('Deleted "${node.title}"'),
      // A snack bar with an action stays until it is used, unless told
      // otherwise -- and it would hold back every message after it.
      persist: false,
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          final String message;
          if (!nodes.undoDelete(node.id, deletedAt)) {
            message = 'Too late to undo: the page has changed since.';
          } else if (nodes.byTitle(node.title)?.id != node.id) {
            message = 'Restored. Another page is called '
                '"${node.title}" too.';
          } else {
            return;
          }
          messenger.showSnackBar(SnackBar(content: Text(message)));
        },
      ),
    ));
  }

  Future<bool> _confirmLeave() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text(
          'This page has changes that are not saved. Following the link '
          'discards them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard and follow'),
          ),
        ],
      ),
    );
    return choice ?? false;
  }

  Future<bool> _confirmReplaceTyping() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace unsaved changes?'),
        content: const Text(
          'You have changes that are not saved yet. Loading the earlier '
          'version replaces them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep my changes'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Load earlier version'),
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

  /// Ctrl+S (Cmd+S on a Mac) saves, as in every editor; the browser's own
  /// "save page as" would only download the app.
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            _save();
          },
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
            _save();
          },
        },
        // Somewhere to hold focus in Read mode, where there is no text field.
        child: Focus(autofocus: true, child: _page(context)),
      );

  Widget _page(BuildContext context) {
    final node = _node;
    final backlinks = node == null
        ? const <NodeSummary>[]
        : widget.nodes.backlinks(node.titleKey);
    // From the link index, so as saved: parsing the text on every keystroke
    // is a full Markdown parse, which a long page makes slow.
    final targets =
        node == null ? const <String>[] : widget.nodes.linksFrom(node.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          node == null
              ? 'New page'
              : _reading
                  ? (_title.text.trim().isEmpty ? '(untitled)' : _title.text)
                  : 'Edit page',
        ),
        actions: [
          if (node != null)
            IconButton(
              tooltip: _reading ? 'Edit' : 'Read',
              icon: Icon(
                _reading
                    ? Icons.edit_outlined
                    : Icons.chrome_reader_mode_outlined,
              ),
              onPressed: () => setState(() => _reading = !_reading),
            ),
          if (node != null)
            IconButton(
              tooltip: 'History',
              icon: const Icon(Icons.history),
              onPressed: () => _openHistory(node.id),
            ),
          if (node != null)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(node),
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
          if (_reading && _dirty)
            MaterialBanner(
              content: const Text(
                'This shows unsaved changes. Save to keep them.',
              ),
              actions: [
                TextButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          if (_reading)
            PageMarkdown(
              body: _body.text,
              imageBytes: _imageBytes,
              onWikiLink: _follow,
              onExternalLink: _openExternal,
            )
          else ...[
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
                  helperText: 'Markdown. Link with [[Another Page]] -- a page '
                      'that does not exist yet is fine. Show an attached image '
                      'with ![description](file name). A line '
                      '"Question :: Answer" becomes a flashcard.',
                  helperMaxLines: 4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          AttachmentsSection(
            db: widget.db,
            nodeId: node?.id,
            pageDeleted: _deletedElsewhere,
          ),
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

  /// Shows the server's history of this page; a chosen version lands in the
  /// editor, unsaved.
  Future<void> _openHistory(String nodeId) async {
    final url = Uri.tryParse(widget.db.meta(MetaKeys.serverUrl) ?? '');
    final token = widget.db.meta(MetaKeys.token) ?? '';
    if (url == null || !url.hasScheme || token.isEmpty) {
      _snack('The history is kept by the server. Sign in under Settings to '
          'see it.');
      return;
    }
    final api = SyncApiClient(baseUrl: url, token: token);
    final PageVersion? version;
    try {
      version = await Navigator.of(context).push<PageVersion>(
        MaterialPageRoute(
          builder: (_) => HistoryPage(
            load: () => api.history('nodes', nodeId),
            shown: PageVersion(title: _title.text, body: _body.text),
          ),
        ),
      );
    } finally {
      api.close();
    }
    if (version == null || !mounted) {
      return;
    }
    if (_dirty && !await _confirmReplaceTyping()) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      // Shown as text, so it is plain that this is an unsaved edit.
      _reading = false;
      _title.text = version!.title;
      _body.text = version.body;
    });
    _snack('Earlier version loaded. Save to keep it.');
  }

  /// Follows a [[link]], creating the target page if it does not exist yet.
  Future<void> _follow(String titleKey) async {
    if (normalizeTitle(titleKey).isEmpty) {
      return;
    }
    // Leaving replaces this editor: unsaved typing would be gone without a
    // word, and in Read mode it does not even look unsaved.
    if (_dirty && !await _confirmLeave()) {
      return;
    }
    if (!mounted) {
      return;
    }
    final existing = widget.nodes.byTitle(titleKey);
    final id = existing?.id ?? widget.nodes.save(title: titleKey, body: '');
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) =>
          NodeEditor(db: widget.db, nodes: widget.nodes, nodeId: id),
    ));
  }
}
