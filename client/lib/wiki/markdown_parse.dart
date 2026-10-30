/// How a page body is parsed as Markdown: one parse for what PageMarkdown
/// shows and for the link index, so that backlinks list exactly the pages
/// that show a link.
library;

import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// The URL scheme a `[[wiki link]]` is rendered with. Never leaves the app.
const String wikiLinkScheme = 'giki-page';

/// Turns `[[Title]]` and `[[Title|label]]` into links to [wikiLinkScheme].
///
/// It is an inline syntax, so a `[[link]]` inside a code span or block stays
/// text. The link index (lib/wiki/wikilink.dart) reads the same parse, so
/// such a link is no backlink either.
class WikiLinkSyntax extends md.InlineSyntax {
  WikiLinkSyntax() : super(r'\[\[([^\[\]|]+)(?:\|([^\[\]]*))?\]\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final target = match[1]!.trim();
    final label = (match[2] ?? '').trim();
    if (target.isEmpty) {
      // `[[ |label]]` points nowhere; following it would create an untitled
      // page on every tap.
      parser.addNode(md.Text(match[0]!));
      return true;
    }
    final link = md.Element.text('a', label.isEmpty ? target : label)
      ..attributes['href'] = '$wikiLinkScheme:${Uri.encodeComponent(target)}';
    parser.addNode(link);
    return true;
  }
}

/// The page title a [wikiLinkScheme] href points at, or null for any other
/// link.
String? wikiLinkTarget(String? href) {
  if (href == null || !href.startsWith('$wikiLinkScheme:')) {
    return null;
  }
  return percentDecode(href.substring(wikiLinkScheme.length + 1));
}

/// Percent-decodes [text], or returns null when it is not valid. Page text
/// comes from every device: `%FF` must not take a page down for everyone.
String? percentDecode(String text) {
  try {
    return Uri.decodeComponent(text);
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
}

/// Block syntaxes tried before the extension set's.
///
/// markdown 7.3.1's GitHub flavour tries its checkbox-list syntax before the
/// setext heading, so a paragraph followed by a lone `-` line became an empty
/// list item and the paragraph's text was gone. CommonMark (and GitHub) make
/// it a heading; trying the heading syntax first does that, and leaves lists,
/// rules and tables as they were.
const List<md.BlockSyntax> pageBlockSyntaxes = [md.SetextHeaderSyntax()];

/// A Markdown document set up exactly as PageMarkdown renders one.
md.Document pageDocument() => md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: pageBlockSyntaxes,
      inlineSyntaxes: [WikiLinkSyntax()],
      encodeHtml: false,
    );

/// Parses [body] the way PageMarkdown does.
List<md.Node> parsePage(String body) =>
    pageDocument().parseLines(const LineSplitter().convert(body));

/// A backslash ending a line; an even run is escaped backslashes.
final RegExp _trailingBackslash = RegExp(r'(?<!\\)((?:\\\\)*\\)$');

/// [body] in a form the Markdown parser does not crash on, or null when there
/// is none.
///
/// markdown 7.3.1 throws a RangeError on a block that starts with `[` and
/// ends with a backslash -- `[C:\Temp\` as a page's last line is enough.
/// Page text comes from every device, so one such line would make the page
/// unreadable everywhere. The workaround puts a space after a backslash that
/// ends a line, and only when the text as written does not parse: first on
/// lines that end a paragraph, where a backslash is shown as it is anyway,
/// and only if that is not enough on every line, which drops the hard line
/// breaks a backslash makes inside a paragraph.
String? renderableMarkdown(String body) => parseRenderable(body)?.source;

/// The text PageMarkdown renders for [body] (see [renderableMarkdown]) and
/// its parse, or null when the page is shown as plain text.
({String source, List<md.Node> nodes})? parseRenderable(String body) {
  final nodes = _tryParse(body);
  if (nodes != null) {
    return (source: body, nodes: nodes);
  }
  final lines = const LineSplitter().convert(body);
  String patch(bool Function(int index) where) => [
        for (var i = 0; i < lines.length; i++)
          where(i)
              ? lines[i]
                  .replaceFirstMapped(_trailingBackslash, (m) => '${m[1]} ')
              : lines[i],
      ].join('\n');
  for (final patched in [
    patch((i) => i == lines.length - 1 || lines[i + 1].trim().isEmpty),
    patch((_) => true),
  ]) {
    final patchedNodes = _tryParse(patched);
    if (patchedNodes != null) {
      return (source: patched, nodes: patchedNodes);
    }
  }
  return null;
}

List<md.Node>? _tryParse(String body) {
  try {
    return parsePage(body);
  } on Object {
    return null;
  }
}
