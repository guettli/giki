/// [[WikiLink]] parsing, mirroring internal/wikilink in the Go server.
///
/// The two implementations must agree, because the client derives its link
/// index offline and the server derives the same index when a node arrives
/// over sync. Both sides run the same cases, from
/// internal/wikilink/testdata/cases.json: see test_vm/wikilink_test.dart here
/// and TestParse in internal/wikilink/wikilink_test.go on the server.
///
/// Only links that are rendered as links count: a [[link]] in a code block,
/// in a `code span` or after a backslash is shown as text (see
/// lib/wiki/markdown_view.dart), so it must not show up in backlinks either.
library;

final RegExp _linkPattern = RegExp(r'\[\[([^\[\]|]+)(?:\|[^\[\]]*)?\]\]');

/// A code fence, also one inside a quote or a list item: "> ```" and
/// "1. ```" open code blocks too.
final RegExp _fencePattern = RegExp(
    r'^(?:[ \t]*(?:>|(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)))*[ \t]*(`{3,}|~{3,})(.*)$');
final RegExp _listItemPattern =
    RegExp(r'^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)');

/// Lines that start a new block, and with it a new run of inline text:
/// headings, quotes, list items, table rows.
final RegExp _blockStartPattern =
    RegExp(r'^ {0,3}(?:#{1,6}(?:[ \t]|$)|>|[-*+][ \t]|\d{1,9}[.)][ \t]|\|)');

final RegExp _lineEnding = RegExp(r'\r\n?');

const String _asciiPunct = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

/// Maps a human title to its title_key: trimmed, inner whitespace collapsed,
/// lowercased.
String normalizeTitle(String title) => title
    .trim()
    .split(RegExp(r'\s+'))
    .where((p) => p.isNotEmpty)
    .join(' ')
    .toLowerCase();

/// Returns the normalized title_keys referenced by [body], in first-seen order
/// and without duplicates.
List<String> parseLinks(String body) {
  final keys = <String>[];
  final seen = <String>{};
  for (final text in _inlineTexts(body)) {
    for (final target in _scanInline(text)) {
      final key = normalizeTitle(target);
      if (key.isEmpty || !seen.add(key)) {
        continue;
      }
      keys.add(key);
    }
  }
  return keys;
}

/// Splits [body] into the runs of text that Markdown parses for inline
/// syntax, leaving out fenced and indented code blocks.
List<String> _inlineTexts(String body) {
  final texts = <String>[];
  var run = <String>[];
  void flush() {
    if (run.isNotEmpty) {
      texts.add(run.join('\n'));
      run = [];
    }
  }

  String? fence;
  var inList =
      false; // the last block that started at the margin is a list item
  var prevBlank = true; // the previous line was blank, or there was none
  var prevIndented = false;
  for (final line in body.replaceAll(_lineEnding, '\n').split('\n')) {
    if (fence != null) {
      // CommonMark: the closing fence uses the same character, is at least
      // as long as the opening one, and has no info string.
      final m = _fencePattern.firstMatch(line);
      if (m != null &&
          m.group(1)!.startsWith(fence) &&
          m.group(2)!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
      prevBlank = true;
      continue;
    }
    final indented = _indent(line) >= 4;
    if (indented && !inList && (prevBlank || prevIndented)) {
      flush(); // an indented code block
      prevBlank = false;
      prevIndented = true;
      continue;
    }
    prevBlank = prevIndented = false;
    final m = _fencePattern.firstMatch(line);
    if (m != null && !(m.group(1)![0] == '`' && m.group(2)!.contains('`'))) {
      flush();
      fence = m.group(1);
      continue;
    }
    if (!indented) {
      inList = _listItemPattern.hasMatch(line);
    }
    if (_blockStartPattern.hasMatch(line)) {
      flush();
    }
    run.add(line);
  }
  flush();
  return texts;
}

/// The width of [line]'s leading whitespace, a tab counting as four.
int _indent(String line) {
  var width = 0;
  for (final c in line.split('')) {
    if (c == ' ') {
      width++;
    } else if (c == '\t') {
      width += 4 - width % 4;
    } else {
      break;
    }
  }
  return width;
}

/// The targets of the [[links]] in [text], read left to right the way the
/// Markdown inline parser does: a backslash escapes the next punctuation
/// character, a code span hides everything inside it, and the `![` that opens
/// an image takes the bracket, so `![[Page]]` is no link.
List<String> _scanInline(String text) {
  final targets = <String>[];
  var i = 0;
  while (i < text.length) {
    if (text[i] == r'\' &&
        i + 1 < text.length &&
        _asciiPunct.contains(text[i + 1])) {
      i += 2;
    } else if (text.startsWith('![', i)) {
      i += 2;
    } else if (text[i] == '`') {
      i = _skipCodeSpan(text, i);
    } else if (text.startsWith('[[', i)) {
      final m = _linkPattern.matchAsPrefix(text, i);
      if (m != null) {
        targets.add(m.group(1)!);
        i = m.end;
      } else {
        i++;
      }
    } else {
      i++;
    }
  }
  return targets;
}

/// Where scanning continues after the backtick run at [start]: past the
/// closing run of the same length, or past the opening run when there is
/// none and the backticks are literal.
int _skipCodeSpan(String text, int start) {
  final open = _runLength(text, start);
  var i = start + open;
  while (i < text.length) {
    if (text[i] != '`') {
      i++;
      continue;
    }
    final n = _runLength(text, i);
    if (n == open) {
      return i + n;
    }
    i += n;
  }
  return start + open;
}

int _runLength(String text, int start) {
  var n = 0;
  while (start + n < text.length && text[start + n] == '`') {
    n++;
  }
  return n;
}
