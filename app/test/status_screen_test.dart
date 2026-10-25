import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/status/status_screen.dart';

void main() {
  testWidgets(
      'browser status works without embedded application update controls',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatusScreen(
      config: AppConfig.defaults(),
      bridge: NativeCoreBridge(),
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Flight Deck updates'), findsNothing);
    expect(find.text('Apply update'), findsNothing);
  });
}
