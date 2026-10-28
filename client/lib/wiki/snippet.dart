/// Search snippets, rendered.
library;

import 'package:flutter/material.dart';

import '../db/search.dart';

/// Renders a search snippet with its matched terms in bold.
TextSpan highlightSnippet(String snippet, ThemeData theme) {
  final spans = <TextSpan>[];
  final bold = TextStyle(
    fontWeight: FontWeight.bold,
    color: theme.colorScheme.primary,
  );
  var rest = snippet;
  while (rest.isNotEmpty) {
    final start = rest.indexOf(matchStart);
    if (start < 0) {
      spans.add(TextSpan(text: rest));
      break;
    }
    final end = rest.indexOf(matchEnd, start);
    if (end < 0) {
      spans.add(TextSpan(text: rest.replaceAll(matchStart, '')));
      break;
    }
    if (start > 0) {
      spans.add(TextSpan(text: rest.substring(0, start)));
    }
    spans.add(TextSpan(text: rest.substring(start + 1, end), style: bold));
    rest = rest.substring(end + 1);
  }
  return TextSpan(children: spans);
}
