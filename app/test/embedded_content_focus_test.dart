import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/embedded_content_focus.dart';

void main() {
  testWidgets('native page touch releases menu focus without consuming keys',
      (tester) async {
    final menu = FocusNode();
    var opened = 0;
    final events = <KeyEvent>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
          IconButton(
              focusNode: menu,
              onPressed: () => opened++,
              icon: const Icon(Icons.menu)),
          Expanded(
              child: Focus(
                  onKeyEvent: (_, event) {
                    events.add(event);
                    return KeyEventResult.ignored;
                  },
                  child: const EmbeddedContentFocus(
                      child: ColoredBox(
                          key: ValueKey('page'), color: Colors.white)))),
        ]))));
    menu.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(opened, 1);
    await tester.tap(find.byKey(const ValueKey('page')));
    await tester.pump();
    expect(menu.hasFocus, isFalse);
    for (final key in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.keyA
    ]) {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyRepeatEvent(key);
      await tester.sendKeyUpEvent(key);
    }
    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
    expect(opened, 1);
    expect(events.whereType<KeyRepeatEvent>(), hasLength(3));
    expect(events.where((e) => e.logicalKey == LogicalKeyboardKey.space),
        isNotEmpty);
    menu.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    menu.dispose();
  });
  testWidgets('software text input preserves spaces and composition',
      (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EmbeddedContentFocus(
                child: TextField(controller: controller)))));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'two words ',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 4, end: 9)));
    await tester.pump();
    expect(controller.text, 'two words ');
    expect(controller.value.composing, const TextRange(start: 4, end: 9));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
