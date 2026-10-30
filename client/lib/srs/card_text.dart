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
final RegExp _fence = RegExp(r'^(`{3,}|~{3,})(.*)$');

/// The cards written in [body]: every line of the form `front :: back`.
///
/// A list marker in front is ignored, so a list of questions works. Code is
/// not cards -- C++ and Haskell use `::` without meaning it: lines in fenced
/// or indented code blocks are skipped, and so is a line whose separator sits
/// inside an inline `code span`. Both sides must be non-empty, and a question that
/// appears twice counts once, first one wins: the question is what
/// identifies a card (see [cardKey]).
List<CardLine> parseCardLines(String body) =>
    [for (final at in cardLinesAt(body)) at.card];

/// A card line and where it is in the page text.
class CardLineAt {
  const CardLineAt(this.card, this.lineIndex, this.prefix);

  final CardLine card;

  /// The index of the line in `body.split('\n')`.
  final int lineIndex;

  /// What precedes the question on that line: indentation and list marker.
  final String prefix;
}

/// The cards of [parseCardLines], with the lines that write them.
List<CardLineAt> cardLinesAt(String body) {
  final cards = <CardLineAt>[];
  final seen = <String>{};
  String? fence;
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final line = raw.trim();
    final opening = _fence.firstMatch(line);
    if (fence != null) {
      // CommonMark: the closing fence uses the same character, is at least
      // as long as the opening one, and has no info string.
      if (opening != null &&
          opening.group(1)!.startsWith(fence) &&
          opening.group(2)!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (opening != null) {
      fence = opening.group(1);
      continue;
    }
    if (raw.startsWith('    ') || raw.startsWith('\t')) {
      continue; // an indented code block
    }
    final at = line.indexOf(' :: ');
    if (at < 0 || '`'.allMatches(line.substring(0, at)).length.isOdd) {
      continue;
    }
    final question = line.substring(0, at);
    final marker = _listMarker.matchAsPrefix(question)?.group(0) ?? '';
    final front = question.substring(marker.length).trim();
    final back = line.substring(at + 4).trim();
    if (front.isEmpty || back.isEmpty || !seen.add(cardKey(front))) {
      continue;
    }
    final indent = raw.substring(0, raw.length - raw.trimLeft().length);
    cards.add(CardLineAt(CardLine(front, back), i, indent + marker));
  }
  return cards;
}

/// What identifies a card written in a page: its question, ignoring case and
/// spacing. Fixing a typo in the answer, or the capitalisation of the
/// question, keeps the card -- and with it the review schedule.
String cardKey(String front) =>
    front.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();
