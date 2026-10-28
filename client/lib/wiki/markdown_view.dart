/// A page body rendered as Markdown, with `[[wiki links]]` and images from the
/// page's own attachments.
library;

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
    // SelectionArea rather than `selectable: true`: that renders editable
    // text fields, in which a link is no longer a plain tap target.
    return SelectionArea(
      child: MarkdownBody(
        data: body,
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
