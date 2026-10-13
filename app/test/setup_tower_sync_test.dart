import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/setup/setup_screen.dart';

void main() {
  Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  Future<void> pumpSetup(WidgetTester tester, AppConfig config,
      ValueChanged<AppConfig> save) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SetupScreen(
      config: config,
      localFlightDeckUrl: 'http://localhost:47831',
      bridge: NativeCoreBridge(),
      fipsRuntime: FipsRuntimeService(
          isMacOS: false, isLinux: false, isAndroid: false, isIOS: false),
      onConfigChanged: save,
      onClearBrowserData: () async {},
      onOpenFipsApp: (_) {},
    ))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'default Setup pairs in workspace without native Tower configuration',
      (tester) async {
    AppConfig? saved;
    await pumpSetup(tester, AppConfig.defaults(), (value) => saved = value);
    await reveal(tester, field('Flight Deck URL'));
    expect(field('Tower URL'), findsNothing);
    expect(
        find.textContaining('No native Tower URL is needed.'), findsOneWidget);
    await tester.enterText(
        field('Flight Deck URL'), 'https://deck.example/app');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.towerUrl, isEmpty);
    expect(saved!.flightDeckUrl, 'https://deck.example/app');
    expect(saved!.displayExperimentalFlightDeckDriveSync, isFalse);
  });

  testWidgets(
      'normal Setup preserves identity and existing hidden settings on Save',
      (tester) async {
    final config = AppConfig.defaults().copyWith(
      towerUrl: 'https://tower.example',
      flightDeckUrl: 'https://deck.example/workspace',
      appNpub: 'app-fixture',
      workspaceId: 'workspace-fixture',
      workspaceServiceNpub: 'service-fixture',
      channelId: 'channel-fixture',
      deviceNpub: 'identity-fixture',
      devicePublicKeyHex: 'public-fixture',
      deviceSecret: 'non-key-fixture',
      registrationSecret: 'non-key-registration-fixture',
      trustedOrigins: ['https://wapp.example'],
      rememberNip98Approvals: false,
    );
    AppConfig? saved;
    await pumpSetup(tester, config, (value) => saved = value);
    await reveal(tester, field('Flight Deck URL'));
    expect(field('Tower URL'), findsNothing);
    expect(tester.widget<TextField>(field('Flight Deck URL')).controller!.text,
        config.flightDeckUrl);
    await reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved!.towerUrl, config.towerUrl);
    expect(saved!.flightDeckUrl, config.flightDeckUrl);
    expect(saved!.appNpub, config.appNpub);
    expect(saved!.workspaceId, config.workspaceId);
    expect(saved!.workspaceServiceNpub, config.workspaceServiceNpub);
    expect(saved!.channelId, config.channelId);
    expect(saved!.deviceNpub, config.deviceNpub);
    expect(saved!.devicePublicKeyHex, config.devicePublicKeyHex);
    expect(saved!.deviceSecret, config.deviceSecret);
    expect(saved!.registrationSecret, config.registrationSecret);
    expect(saved!.trustedOrigins, config.trustedOrigins);
    expect(saved!.rememberNip98Approvals, isFalse);
    expect(saved!.displayExperimentalFlightDeckDriveSync, isFalse);
  });
}
