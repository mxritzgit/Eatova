// Layout assertions for large-text checks: a word must not be split across
// lines ("Tag|e", "workou|t") and a value must not be cut to an ellipsis.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every [RenderParagraph] below [scope] whose text contains [text].
List<RenderParagraph> paragraphsWith(
  WidgetTester tester,
  Finder scope,
  String text,
) => [
  for (final element in find
      .descendant(of: scope, matching: find.byType(RichText))
      .evaluate())
    if ((element.widget as RichText).text.toPlainText().contains(text))
      element.renderObject! as RenderParagraph,
];

/// Fails when a word of [paragraph] wraps onto two lines or its text is
/// truncated by `maxLines`.
void expectWholeWords(RenderParagraph paragraph, {String? reason}) {
  final text = paragraph.text.toPlainText();
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '${reason ?? text}: truncated',
  );
  for (final word in RegExp(r'\S+').allMatches(text)) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: word.start, extentOffset: word.end),
    );
    final lines = boxes.map((b) => b.top.round()).toSet();
    expect(
      lines,
      hasLength(1),
      reason: '${reason ?? text}: "${word.group(0)}" splits across lines',
    );
  }
}

/// [expectWholeWords] for every paragraph below [scope] containing [text];
/// fails when there is none.
void expectWholeWordsIn(WidgetTester tester, Finder scope, String text) {
  final paragraphs = paragraphsWith(tester, scope, text);
  expect(paragraphs, isNotEmpty, reason: 'no text containing "$text"');
  for (final paragraph in paragraphs) {
    expectWholeWords(paragraph, reason: text);
  }
}
