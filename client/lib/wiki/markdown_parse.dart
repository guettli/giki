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

/// A Markdown document set up exactly as PageMarkdown renders one.
md.Document pageDocument() => md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
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
/// ends a line, which only drops a hard line break; it is used only when the
/// text as written does not parse.
String? renderableMarkdown(String body) => parseRenderable(body)?.source;

/// The text PageMarkdown renders for [body] (see [renderableMarkdown]) and
/// its parse, or null when the page is shown as plain text.
({String source, List<md.Node> nodes})? parseRenderable(String body) {
  final nodes = _tryParse(body);
  if (nodes != null) {
    return (source: body, nodes: nodes);
  }
  final patched = const LineSplitter()
      .convert(body)
      .map((line) =>
          line.replaceFirstMapped(_trailingBackslash, (m) => '${m[1]} '))
      .join('\n');
  final patchedNodes = _tryParse(patched);
  return patchedNodes == null ? null : (source: patched, nodes: patchedNodes);
}

List<md.Node>? _tryParse(String body) {
  try {
    return parsePage(body);
  } on Object {
    return null;
  }
}
