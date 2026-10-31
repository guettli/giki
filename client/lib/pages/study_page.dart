/// The study session: one due card at a time, four ratings, no network.
library;

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../db/page_cards.dart';
import '../db/repository.dart';
import '../srs/card_text.dart';
import '../srs/srs.dart';
import 'wiki_page.dart';

/// Reviews the cards that are due.
class StudyPage extends StatefulWidget {
  const StudyPage({
    required this.db,
    required this.cards,
    required this.nodes,
    super.key,
  });

  /// The local database.
  final GikiDatabase db;

  /// Card storage.
  final CardRepository cards;

  /// Page storage: a card written in a page is edited through its line.
  final NodeRepository nodes;

  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  /// The card whose answer is showing. An id rather than a flag: every sync
  /// rebuilds this page, and when it takes the shown card away (deleted or
  /// answered on another device), the next one must start with its answer
  /// hidden.
  String? _revealedCardId;

  @override
  Widget build(BuildContext context) {
    final due = widget.cards.due();
    if (due.isEmpty) {
      return Scaffold(
        body: const Center(
            child: Text('Nothing due. Add a card or come back later.')),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _editCard(null),
          tooltip: 'New card',
          child: const Icon(Icons.add),
        ),
      );
    }

    final card = due.first;
    final revealed = _revealedCardId == card.cardId;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${due.length} due  ·  box ${card.state.box} of $maxBox',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: 'Edit card',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editCard(card),
                        ),
                        IconButton(
                          tooltip: 'Delete card',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteCard(card),
                        ),
                      ],
                    ),
                    Text(card.front,
                        style: Theme.of(context).textTheme.headlineSmall),
                    if (card.pageTitle case final title?)
                      TextButton.icon(
                        icon: const Icon(Icons.description_outlined),
                        label: Text('From "$title"'),
                        onPressed: () => _openPage(card.nodeId),
                      ),
                    if (revealed) ...[
                      const Divider(height: 32),
                      Text(card.back,
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ],
                ),
              ),
            ),
            const Spacer(),
            if (!revealed)
              FilledButton(
                onPressed: () => setState(() => _revealedCardId = card.cardId),
                child: const Text('Show answer'),
              )
            else
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final rating in Rating.values)
                    FilledButton.tonal(
                      onPressed: () => _rate(card, rating),
                      child: Text(rating.name),
                    ),
                ],
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editCard(null),
        tooltip: 'New card',
        child: const Icon(Icons.add),
      ),
    );
  }

  void _rate(DueCard card, Rating rating) {
    widget.cards.review(card, rating);
    setState(() => _revealedCardId = null);
  }

  /// The page and the line that write [card], or null for a card made here
  /// -- or one whose page or line is gone.
  (Node, CardLineAt)? _pageLine(DueCard? card) {
    if (card == null || card.nodeId.isEmpty) {
      return null;
    }
    final node = widget.nodes.byId(card.nodeId);
    final line = node == null
        ? null
        : pageCardLine(node.body, nodeId: node.id, cardId: card.cardId);
    return line == null ? null : (node!, line);
  }

  /// Creates a card, or edits [card].
  ///
  /// A card written in a page is edited through its line, so the page says
  /// what the card says, and the next edit of the page keeps the change.
  Future<void> _editCard(DueCard? card) async {
    final page = _pageLine(card);
    final sides = await showDialog<(String, String)>(
      context: context,
      builder: (context) => _CardDialog(card: card, pageTitle: page?.$1.title),
    );
    if (sides == null) {
      return;
    }
    if (card == null) {
      widget.cards.save(front: sides.$1, back: sides.$2);
    } else if (page == null) {
      if (!widget.cards.update(card.cardId, front: sides.$1, back: sides.$2)) {
        _goneMeanwhile('This card was deleted on another device. '
            'Nothing was saved.');
        return;
      }
    } else if (_pageLine(card) case (final node, final line)) {
      // Read again: a sync may have changed the page while the dialog was
      // open, and writing the text from before it would undo that change.
      final body =
          editPageCardLine(node.body, line, front: sides.$1, back: sides.$2);
      if (body == null) {
        _tell('That does not fit on its line in "${node.title}": a question '
            'can be asked only once per page, and cannot contain " :: ".');
        return;
      }
      widget.nodes.save(id: node.id, title: node.title, body: body);
    } else {
      _goneMeanwhile(_changedElsewhere(card, page.$1.title, 'saved'));
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _deleteCard(DueCard card) async {
    final page = _pageLine(card);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text(page == null
            ? '"${card.front}" is removed on every device.'
            : '"${card.front}" is removed on every device, and so is its '
                'line in "${page.$1.title}".'),
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
    if (!(confirmed ?? false)) {
      return;
    }
    if (page == null) {
      if (!widget.cards.delete(card.cardId)) {
        _goneMeanwhile('This card was already deleted on another device.');
        return;
      }
    } else if (_pageLine(card) case (final node, final line)) {
      // Read again, as in _editCard. Removing the line deletes the card: the
      // page and its cards change in one transaction.
      final body = editPageCardLine(node.body, line);
      if (body == null) {
        _tell('"${node.title}" asks this question again further down, so '
            'the card would stay. Open the page to remove both lines.');
        return;
      }
      widget.nodes.save(id: node.id, title: node.title, body: body);
    } else {
      _goneMeanwhile(_changedElsewhere(card, page.$1.title, 'deleted'));
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Why a card's page could not be written: the page is gone, or the
  /// card's line in it changed.
  String _changedElsewhere(DueCard card, String title, String verb) =>
      widget.nodes.byId(card.nodeId) == null
          ? '"$title" was deleted on another device. Nothing was $verb.'
          : 'The card\'s line in "$title" changed meanwhile, on another '
              'device. Nothing was $verb.';

  /// Says why nothing happened, and shows the queue as it is now: the card
  /// the user acted on may no longer be in it.
  void _goneMeanwhile(String message) {
    _tell(message);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openPage(String nodeId) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          NodeEditor(db: widget.db, nodes: widget.nodes, nodeId: nodeId),
    ));
    if (mounted) {
      setState(() {});
    }
  }

  void _tell(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

/// The front and back of a card, both required: a card with an empty side
/// cannot be studied, and used to sit in the queue for good.
///
/// A widget of its own so that it owns the text controllers. Disposed by the
/// caller right after showDialog returned, they were still in use by the
/// dialog's closing animation.
class _CardDialog extends StatefulWidget {
  const _CardDialog({required this.card, this.pageTitle});

  final DueCard? card;

  /// The page whose line the card is written in, if any.
  final String? pageTitle;

  @override
  State<_CardDialog> createState() => _CardDialogState();
}

class _CardDialogState extends State<_CardDialog> {
  late final TextEditingController _front =
      TextEditingController(text: widget.card?.front ?? '');
  late final TextEditingController _back =
      TextEditingController(text: widget.card?.back ?? '');

  @override
  void dispose() {
    _front.dispose();
    _back.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final complete =
        _front.text.trim().isNotEmpty && _back.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.card == null ? 'New card' : 'Edit card'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.pageTitle case final title?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Saved to its line in "$title". A changed question makes '
                'it a new card, which starts its reviews over.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Semantics(
              textField: true,
              label: 'Front',
              child: TextField(
                controller: _front,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Front'),
              )),
          Semantics(
              textField: true,
              label: 'Back',
              child: TextField(
                controller: _back,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Back'),
              )),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: complete
              ? () => Navigator.of(context)
                  .pop((_front.text.trim(), _back.text.trim()))
              : null,
          child: Text(widget.card == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
