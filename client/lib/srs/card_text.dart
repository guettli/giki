/// Flashcards written inside a page: one `Question :: Answer` per line.
library;

/// A card as written in a page's text.
class CardLine {
  const CardLine(this.front, this.back);

  final String front;
  final String back;

  @override
  bool operator ==(Object other) =>
      other is CardLine && other.front == front && other.back == back;

  @override
  int get hashCode => Object.hash(front, back);

  @override
  String toString() => 'CardLine($front :: $back)';
}

final RegExp _listMarker = RegExp(r'^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?');
final RegExp _fence = RegExp(r'^(`{3,}|~{3,})');

/// The cards written in [body]: every line of the form `front :: back`.
///
/// A list marker in front is ignored, so a list of questions works. Lines in
/// fenced code blocks are not cards -- code can contain `::` (C++, Haskell)
/// without meaning it. Both sides must be non-empty, and a question that
/// appears twice counts once, first one wins: the question is what
/// identifies a card (see [cardKey]).
List<CardLine> parseCardLines(String body) {
  final cards = <CardLine>[];
  final seen = <String>{};
  String? fence;
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    final opening = _fence.firstMatch(line);
    if (fence != null) {
      if (opening != null && line.startsWith(fence)) {
        fence = null;
      }
      continue;
    }
    if (opening != null) {
      fence = opening.group(1)![0] * 3;
      continue;
    }
    final at = line.indexOf(' :: ');
    if (at < 0) {
      continue;
    }
    final front = line.substring(0, at).replaceFirst(_listMarker, '').trim();
    final back = line.substring(at + 4).trim();
    if (front.isEmpty || back.isEmpty || !seen.add(cardKey(front))) {
      continue;
    }
    cards.add(CardLine(front, back));
  }
  return cards;
}

/// What identifies a card written in a page: its question, ignoring case and
/// spacing. Fixing a typo in the answer, or the capitalisation of the
/// question, keeps the card -- and with it the review schedule.
String cardKey(String front) =>
    front.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();
