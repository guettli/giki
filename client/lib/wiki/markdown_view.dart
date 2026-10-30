/// A page body rendered as Markdown, with `[[wiki links]]` and images from the
/// page's own attachments.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// The URL scheme a `[[wiki link]]` is rendered with. Never leaves the app.
const String wikiLinkScheme = 'giki-page';

/// Turns `[[Title]]` and `[[Title|label]]` into links to [wikiLinkScheme].
///
/// The same shape as the link index's pattern (lib/wiki/wikilink.dart). It is
/// an inline syntax, so a `[[link]]` inside a code span or block stays text --
/// unlike the index, which still counts it as a backlink.
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
  return _decode(href.substring(wikiLinkScheme.length + 1));
}

/// Percent-decodes [text], or returns null when it is not valid. Page text
/// comes from every device: `%FF` must not take a page down for everyone.
String? _decode(String text) {
  try {
    return Uri.decodeComponent(text);
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
}

/// Links that may leave the app. Anything else -- javascript:, data:, a
/// relative path -- is not followed: page text comes from every device of
/// every user of the knowledge base.
bool isSafeExternalLink(String? href) {
  final uri = href == null ? null : Uri.tryParse(href);
  return uri != null &&
      const {'http', 'https', 'mailto'}.contains(uri.scheme) &&
      (uri.scheme == 'mailto' || uri.host.isNotEmpty);
}

/// A Markdown document set up exactly as [PageMarkdown] renders one.
md.Document pageDocument() => md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [WikiLinkSyntax()],
      encodeHtml: false,
    );

/// Parses [body] the way [PageMarkdown] does.
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
String? renderableMarkdown(String body) {
  if (_parses(body)) {
    return body;
  }
  final patched = const LineSplitter()
      .convert(body)
      .map((line) =>
          line.replaceFirstMapped(_trailingBackslash, (m) => '${m[1]} '))
      .join('\n');
  return _parses(patched) ? patched : null;
}

bool _parses(String body) {
  try {
    parsePage(body);
    return true;
  } on Object {
    return false;
  }
}

/// Renders [body] as Markdown (GitHub flavour: tables, task lists, fenced
/// code, strikethrough).
///
/// Images are shown only from the page's own attachments, by file name --
/// `![diagram](diagram.png)`. A remote image is not fetched: it would not
/// work offline, and it would tell a third party who reads which page.
class PageMarkdown extends StatelessWidget {
  const PageMarkdown({
    required this.body,
    required this.imageBytes,
    required this.onWikiLink,
    required this.onExternalLink,
    super.key,
  });

  final String body;

  /// The bytes of the attachment called [filename] on this page; null when
  /// there is none, or this device does not have its bytes yet.
  final Uint8List? Function(String filename) imageBytes;

  /// Called with the target title of a tapped `[[wiki link]]`.
  final void Function(String title) onWikiLink;

  /// Called with a tapped http(s) or mailto link.
  final void Function(Uri uri) onExternalLink;

  @override
  Widget build(BuildContext context) {
    if (body.trim().isEmpty) {
      return Text(
        'This page is empty. Choose Edit to write something.',
        style: TextStyle(color: Theme.of(context).hintColor),
      );
    }
    final source = _renderable(body);
    if (source == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This page cannot be formatted, so it is shown as plain text.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          SelectableText(body),
        ],
      );
    }
    // SelectionArea rather than `selectable: true`: that renders editable
    // text fields, in which a link is no longer a plain tap target.
    return SelectionArea(
      child: MarkdownBody(
        data: source,
        inlineSyntaxes: [WikiLinkSyntax()],
        extensionSet: md.ExtensionSet.gitHubFlavored,
        onTapLink: (text, href, title) {
          final target = wikiLinkTarget(href);
          if (target != null) {
            onWikiLink(target);
          } else if (isSafeExternalLink(href)) {
            onExternalLink(Uri.parse(href!));
          }
        },
        imageBuilder: (uri, title, alt) => _image(context, uri, alt),
      ),
    );
  }

  // build runs on every rebuild of the editor, and renderableMarkdown parses
  // the page once more; remember the last answer.
  static String? _lastBody;
  static String? _lastSource;

  static String? _renderable(String body) {
    if (body != _lastBody) {
      _lastSource = renderableMarkdown(body);
      _lastBody = body;
    }
    return _lastSource;
  }

  Widget _image(BuildContext context, Uri uri, String? alt) {
    final label = (alt ?? '').isEmpty ? uri.toString() : alt!;
    if (uri.hasScheme) {
      return _placeholder(
          context, Icons.public_off, 'Remote image not loaded: $label');
    }
    final filename = _decode(uri.path);
    final bytes = filename == null ? null : imageBytes(filename);
    if (bytes == null) {
      return _placeholder(
          context, Icons.image_outlined, 'Image not available: $label');
    }
    return Semantics(
      image: true,
      label: label,
      child: Image.memory(
        bytes,
        errorBuilder: (context, error, stack) => _placeholder(
            context, Icons.broken_image_outlined, 'Cannot show image: $label'),
      ),
    );
  }

  Widget _placeholder(BuildContext context, IconData icon, String text) {
    final color = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}
