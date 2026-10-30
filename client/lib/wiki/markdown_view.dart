/// A page body rendered as Markdown, with `[[wiki links]]` and images from the
/// page's own attachments.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_parse.dart';

export 'markdown_parse.dart';

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
    final filename = percentDecode(uri.path);
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
