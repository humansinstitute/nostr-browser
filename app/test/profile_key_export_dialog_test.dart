import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/profile_key_export_dialog.dart';

void main() {
  testWidgets(
      'requires warning acceptance and PIN, then expires the revealed key',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ProfileKeyExportDialog(unlock: (pin) async {
      calls++;
      if (pin != '1234') throw StateError('wrong pin');
      return 'nsec-test-only';
    }))));
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Reveal nsec'))
            .onPressed,
        isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '9999');
    await tester.tap(find.text('Reveal nsec'));
    await tester.pumpAndSettle();
    expect(find.text('nsec-test-only'), findsNothing);
    expect(find.textContaining('Unable to export.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Reveal nsec'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('nsec-test-only'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('nsec-test-only'), findsNothing);
  });
  testWidgets('backgrounding invalidates an in-flight PIN check',
      (tester) async {
    final pending = Completer<String>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ProfileKeyExportDialog(unlock: (_) => pending.future))));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Reveal nsec'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pending.complete('must-never-be-visible');
    await tester.pumpAndSettle();
    expect(find.text('must-never-be-visible'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
