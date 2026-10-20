import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// WidgetTester.enterText/showKeyboard use exact EditableText runtime types.
// Accept supported EditableText subclasses as well.
Future<void> enterEditorText(
    WidgetTester tester, Finder field, String text) async {
  final editor = find.descendant(
    of: field,
    matching: find.byWidgetPredicate((widget) => widget is EditableText),
    matchRoot: true,
  );
  tester.binding.focusedEditable = tester.state<EditableTextState>(editor);
  await tester.pump();
  tester.testTextInput.enterText(text);
  await tester.pump();
}
