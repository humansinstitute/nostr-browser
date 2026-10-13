import 'dart:async';
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
import 'fake_webview_platform.dart';

const endpoint =
    'http://npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98.fips:8787';
const page = 'https://flightdeck.example',
    tower = 'npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98';

class CountingSigner extends NativeCoreBridge {
  int calls = 0;
  @override
  Future<CoreCommandResult> signEvent(
      {required AppConfig config, required Map<String, dynamic> event}) async {
    calls++;
    return const CoreCommandResult(
        ok: true, json: {'test': 'no private signing material'});
  }
}

class RememberedKind extends SignerStore {
  Completer<void>? gate;
  @override
  Future<SignerPolicyRule?> findPolicyRule(
      {required String pageOrigin,
      required String operation,
      required String target,
      required String deviceNpub}) async {
    await gate?.future;
    return SignerPolicyRule(
        pageOrigin: pageOrigin,
        operation: operation,
        target: target,
        deviceNpub: deviceNpub,
        decision: SignerPolicyRuleDecision.allow,
        createdAt: DateTime.now());
  }

  @override
  Future<void> appendAudit(SignerAuditEntry entry) async {}
}

void main() {
  for (final revoke in [
    'navigation',
    'logout',
    'identity',
    'configuration',
    'unpair'
  ]) {
    testWidgets(
        'remembered mesh grant is exact and revokes during pending $revoke',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await SharedPreferencesAsync()
          .setString('wingman.browser.last_signer_npub.v1', 'test-identity');
      installFakeWebViewPlatform();
      final signer = CountingSigner(), store = RememberedKind();
      final config = AppConfig.defaults().copyWith(
          towerUrl: '',
          flightDeckUrl: page,
          deviceNpub: 'test-identity',
          deviceSecret: 'non-key-test-placeholder');
      Widget app(AppConfig currentConfig) => MaterialApp(
          home: Scaffold(
              body: BrowserScreen(
                  config: currentConfig,
                  localFlightDeckUrl: page,
                  bridge: signer,
                  signerStore: store,
                  onOpenDrawer: () {},
                  onOpenSetup: () {},
                  onOpenSigner: () {},
                  onOpenStatus: () {},
                  onPrepareFipsNavigation: (_) async => null)));
      await tester.pumpWidget(app(config));
      await tester.pumpAndSettle();
      submitFakePageFinished(controllerIndex: 0, url: page);
      await tester.pumpAndSettle();
      final script = fakeExecutedJavaScripts
          .firstWhere((s) => s.contains('const token ='));
      final token = jsonDecode(
          RegExp(r'const token = (.*);').firstMatch(script)!.group(1)!);
      void sign(String id,
          {String? proof,
          String url = '$endpoint/api/test',
          bool relay = false}) {
        submitFakeJavaScriptMessage(
            controllerIndex: 0,
            channel: 'WingmanSigner',
            message: jsonEncode({
              'id': id,
              'method': 'signEvent',
              'towerDocumentToken': proof,
              'params': {
                'kind': relay ? 22242 : 27235,
                'tags': [
                  [relay ? 'relay' : 'u', url],
                  [
                    relay ? 'challenge' : 'method',
                    relay ? 'test-challenge' : 'GET'
                  ]
                ],
                'content': '',
                'created_at': 1
              }
            }));
      }

      sign('before', proof: token);
      await tester.pumpAndSettle();
      expect(signer.calls, 0);
      submitFakeJavaScriptMessage(
          controllerIndex: 0,
          channel: 'WingmanGrasp',
          message: jsonEncode({
            'id': 'connect',
            'token': token,
            'method': 'connect',
            'params': {
              'endpoint': endpoint,
              'peerNpub': tower,
              'purpose': 'tower'
            }
          }));
      await tester.pumpAndSettle();
      if (find.text('Once').evaluate().isNotEmpty) {
        await tester.tap(find.text('Once'));
        await tester.pumpAndSettle();
      }
      sign('forged', proof: 'wrong');
      await tester.pumpAndSettle();
      expect(signer.calls, 0);
      sign('different',
          proof: token,
          url: "${endpoint.replaceFirst(':8787', ':8788')}/api/test");
      await tester.pumpAndSettle();
      expect(signer.calls, 0);
      sign('relay',
          proof: token,
          url: endpoint.replaceFirst('http:', 'ws:'),
          relay: true);
      await tester.pumpAndSettle();
      expect(signer.calls, 0);
      sign('valid', proof: token);
      await tester.pumpAndSettle();
      expect(signer.calls, 1);
      store.gate = Completer<void>();
      sign('pending', proof: token);
      await tester.pump();
      if (revoke == 'navigation') {
        await submitFakeNavigationRequest(
            controllerIndex: 0,
            url: 'https://other.example',
            isMainFrame: true);
      } else if (revoke == 'logout') {
        await tester.pumpWidget(app(config.copyWith(deviceSecret: '')));
      } else if (revoke == 'identity') {
        await tester
            .pumpWidget(app(config.copyWith(deviceNpub: 'other-identity')));
      } else if (revoke == 'configuration') {
        await tester.pumpWidget(
            app(config.copyWith(towerUrl: 'https://other-tower.example')));
      } else {
        await tester.runAsync(() async {
          submitFakeJavaScriptMessage(
              controllerIndex: 0,
              channel: 'WingmanGrasp',
              message: jsonEncode({
                'id': 'unpair',
                'token': token,
                'method': 'disconnect',
                'params': {}
              }));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      }
      store.gate!.complete();
      await tester.pumpAndSettle();
      expect(signer.calls, 1);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
