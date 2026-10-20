import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/onboarding/signer_onboarding_screen.dart';
import 'package:wingman_app/src/features/browser/profile_key_export_dialog.dart';
import 'package:wingman_app/src/widgets/immediate_pin_field.dart';
import 'signer_welcome_test.dart' show TestVault, record;

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty());
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final surface in ['unlock', 'create', 'import', 'export']) {
      testWidgets('$platform $surface immediately masks rendered input',
          (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.binding.platformDispatcher.brieflyShowPasswordTestValue = true;
        addTearDown(tester.binding.platformDispatcher.resetBrieflyShowPassword);
        final vault = TestVault();
        String? exportedPin;
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: surface == 'export'
                    ? ProfileKeyExportDialog(unlock: (pin) async {
                        exportedPin = pin;
                        return 'nsec-test';
                      })
                    : SignerOnboardingScreen(
                        vault: vault,
                        record:
                            surface == 'unlock' ? record('npub-test') : null,
                        onUnlocked: (_) {}))));
        await tester.pumpAndSettle();
        if (surface == 'import') {
          await tester.tap(find.text('Import key'));
          await tester.pumpAndSettle();
        }
        final fields = find.byType(ImmediatePinField);
        expect(fields,
            findsNWidgets(surface == 'create' || surface == 'import' ? 2 : 1));
        Finder editable(Finder field) => find.descendant(
            of: field,
            matching: find.byWidgetPredicate((w) => w is EditableText));
        for (var index = 0; index < fields.evaluate().length; index++) {
          final field = fields.at(index);
          final editor = editable(field);
          final controller = tester.widget<ImmediatePinField>(field).controller;
          await tester.ensureVisible(field);
          tester.binding.focusedEditable =
              tester.state<EditableTextState>(editor);
          await tester.pump();
          expect(
              tester.state<EditableTextState>(editor).widget.focusNode.hasFocus,
              isTrue);
          void check(String value) {
            expect(
                tester
                    .state<EditableTextState>(editor)
                    .renderEditable
                    .text!
                    .toPlainText(),
                '•' * value.length);
            expect(controller.text, value);
            expect(controller.selection,
                TextSelection.collapsed(offset: value.length));
            expect(tester.testTextInput.setClientArgs!['obscureText'], isTrue);
          }

          Future<void> input(String value) async {
            tester.testTextInput.updateEditingValue(TextEditingValue(
                text: value,
                selection: TextSelection.collapsed(offset: value.length)));
            await tester.pump();
            check(value);
            for (var frame = 0; frame < 8; frame++) {
              await tester.pump(const Duration(milliseconds: 250));
              check(value);
            }
          }

          // Incremental typing, backspace, replacement and multi-character paste.
          for (final value in [
            '1',
            '12',
            '123',
            '1234',
            '123',
            '12',
            '129',
            '129567890123'
          ]) {
            await input(value);
          }
          if (surface == 'export') {
            await input('');
            tester.testTextInput.updateEditingValue(const TextEditingValue(
                text: '1234x56789012345',
                selection: TextSelection.collapsed(offset: 15)));
            await tester.pump();
            expect(controller.text, '123456789012');
            expect(
                tester
                    .state<EditableTextState>(editor)
                    .renderEditable
                    .text!
                    .toPlainText(),
                '••••••••••••');
          }
          await input('1234');
          controller.selection =
              const TextSelection(baseOffset: 1, extentOffset: 3);
          await tester.pump();
          tester.testTextInput.updateEditingValue(const TextEditingValue(
              text: '194', selection: TextSelection.collapsed(offset: 2)));
          await tester.pump();
          expect(controller.text, '194');
          expect(
              controller.selection, const TextSelection.collapsed(offset: 2));
          expect(
              tester
                  .state<EditableTextState>(editor)
                  .renderEditable
                  .text!
                  .toPlainText(),
              '•••');
          await input('');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => call.method == 'Clipboard.getData'
                ? <String, dynamic>{'text': '1234'}
                : null,
          );
          await tester
              .state<EditableTextState>(editor)
              .pasteText(SelectionChangedCause.toolbar);
          await tester.pump();
          check('1234');
          tester.binding.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        }
        if (surface != 'export') {
          await tester.ensureVisible(find.byTooltip('Show PIN'));
          await tester.tap(find.byTooltip('Show PIN'));
          await tester.pump();
          for (var i = 0; i < fields.evaluate().length; i++) {
            expect(
                tester
                    .state<EditableTextState>(editable(fields.at(i)))
                    .renderEditable
                    .text!
                    .toPlainText(),
                '1234');
          }
          await tester.tap(find.byTooltip('Hide PIN'));
          await tester.pump();
          for (var i = 0; i < fields.evaluate().length; i++) {
            expect(
                tester
                    .state<EditableTextState>(editable(fields.at(i)))
                    .renderEditable
                    .text!
                    .toPlainText(),
                '••••');
          }
          if (surface == 'unlock') {
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pump();
            expect(vault.unlocks, 1);
            expect(vault.lastPin, '1234');
          }
        } else {
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pump();
          await tester.tap(find.text('Reveal nsec'));
          await tester.pump();
          expect(exportedPin, '1234');
        }
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
  testWidgets('control proves platform latest-digit reveal is active',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.binding.platformDispatcher.brieflyShowPasswordTestValue = true;
    addTearDown(tester.binding.platformDispatcher.resetBrieflyShowPassword);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField(obscureText: true))));
    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '1', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable
            .text!
            .toPlainText(),
        '1');
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
