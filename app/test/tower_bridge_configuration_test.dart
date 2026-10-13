import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'package:wingman_app/src/features/browser/grasp_fips_bridge_script.dart';

import 'fake_webview_platform.dart';

void main() {
  const local = 'http://localhost:47831';
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
  });
  Widget app(AppConfig config) => MaterialApp(
          home: Scaffold(
              body: BrowserScreen(
        config: config,
        localFlightDeckUrl: local,
        bridge: NativeCoreBridge(),
        signerStore: SignerStore(),
        onOpenDrawer: () {},
        onOpenSetup: () {},
        onOpenSigner: () {},
        onOpenStatus: () {},
        onPrepareFipsNavigation: (_) async => null,
      )));
  List<String> scripts() => fakeExecutedJavaScripts
      .where((s) => s.contains('const token ='))
      .toList();

  for (final page in [local, 'https://deck.example/workspace']) {
    testWidgets(
        'universal FIPS provider includes the Tower adapter at eligible $page',
        (tester) async {
      final config =
          AppConfig.defaults().copyWith(flightDeckUrl: 'https://deck.example');
      expect(config.towerUrl, isEmpty);
      await tester.pumpWidget(app(config));
      await tester.pumpAndSettle();
      await submitFakeNavigationRequest(
          controllerIndex: 0, url: page, isMainFrame: true);
      fakeExecutedJavaScripts.clear();
      submitFakePageFinished(controllerIndex: 0, url: page);
      await tester.pumpAndSettle();
      final script = scripts().single;
      final token = jsonDecode(
              RegExp(r'const token = (.*);').firstMatch(script)!.group(1)!)
          as String;
      expect(script, graspFipsBridgeScript(token, Uri.parse(page).origin));
      expect(script, contains("'wingmanTowerTransport'"));
      expect(fakeClearCookieCalls, 0);
      expect(fakeReloadCalls, 0);
    });
  }

  for (final page in [
    'https://wapp.example',
    'http://deck.example',
    'https://deck.example:8443',
    'http://localhost:47832'
  ]) {
    testWidgets(
        'provider origin policy applies independently of Tower at $page',
        (tester) async {
      await tester.pumpWidget(app(AppConfig.defaults()));
      await tester.pumpAndSettle();
      await submitFakeNavigationRequest(
          controllerIndex: 0, url: page, isMainFrame: true);
      fakeExecutedJavaScripts.clear();
      submitFakePageFinished(controllerIndex: 0, url: page);
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(AppConfig.defaults().copyWith(
        towerUrl: 'https://tower.example',
        flightDeckUrl: 'https://deck.example',
        trustedOrigins: [page],
      )));
      await tester.pumpAndSettle();
      await submitFakeNavigationRequest(
          controllerIndex: 0, url: page, isMainFrame: true);
      fakeExecutedJavaScripts.clear();
      submitFakePageFinished(controllerIndex: 0, url: page);
      await tester.pumpAndSettle();
      final supported = Uri.parse(page).scheme == 'https';
      expect(scripts(), supported ? hasLength(1) : isEmpty,
          reason:
              'HTTPS pages receive only a consent-gated generic provider; insecure non-local origins fail closed');
    });
  }
}
