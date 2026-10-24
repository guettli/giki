/// The study session: one due card at a time, four ratings, no network.
library;

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../db/repository.dart';
import '../srs/srs.dart';

/// Reviews the cards that are due.
class StudyPage extends StatefulWidget {
  const StudyPage({required this.db, required this.cards, super.key});

  /// The local database.
  final GikiDatabase db;

  /// Card storage.
  final CardRepository cards;

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

  /// Creates a card, or edits [card]. Both sides are required: a card with
  /// an empty side cannot be studied, and used to sit in the queue for good.
  Future<void> _editCard(DueCard? card) async {
    final front = TextEditingController(text: card?.front ?? '');
    final back = TextEditingController(text: card?.back ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(card == null ? 'New card' : 'Edit card'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
                textField: true,
                label: 'Front',
                child: TextField(
                  controller: front,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Front'),
                )),
            Semantics(
                textField: true,
                label: 'Back',
                child: TextField(
                  controller: back,
                  decoration: const InputDecoration(labelText: 'Back'),
                )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ListenableBuilder(
            listenable: Listenable.merge([front, back]),
            builder: (context, _) => FilledButton(
              onPressed: front.text.trim().isEmpty || back.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: Text(card == null ? 'Create' : 'Save'),
            ),
          ),
        ],
      ),
    );
    if (saved ?? false) {
      widget.cards.save(
          id: card?.cardId, front: front.text.trim(), back: back.text.trim());
      if (mounted) {
        setState(() {});
      }
    }
    front.dispose();
    back.dispose();
  }

  Future<void> _deleteCard(DueCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text('"${card.front}" is removed on every device.'),
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
    if (confirmed ?? false) {
      widget.cards.delete(card.cardId);
      if (mounted) {
        setState(() {});
      }
    }
  }
}
