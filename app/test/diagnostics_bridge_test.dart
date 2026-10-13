import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/browser/diagnostics_store.dart';
import 'fake_webview_platform.dart';
import 'mesh_auth_signing_test.dart' show Harness;

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  Future<Harness> start(WidgetTester tester) async {
    final h = Harness();
    await h.start(tester);
    submitFakePageFinished(
        controllerIndex: 0, url: 'https://flightdeck.example');
    await tester.pumpAndSettle();
    final script = fakeExecutedJavaScripts
        .lastWhere((s) => s.contains('const signerDocumentToken ='));
    h.token = jsonDecode(RegExp(r'const signerDocumentToken = (.*);')
        .firstMatch(script)!
        .group(1)!);
    expect(script, contains("'wingmanDiagnostics'"));
    return h;
  }

  void rpc(Harness h, String id, String method,
      {String workspace = 'workspace', bool enabled = true, String? token}) {
    h.sign(id, method: 'diagnostics.$method', proof: token, event: {
      'workspaceId': workspace,
      'enabled': enabled,
      'events': [
        {
          'ts': DateTime.now().millisecondsSinceEpoch,
          'source': 'browser',
          'level': 'error',
          'code': 'browser.error',
          'message': 'secret'
        }
      ],
    });
  }

  bool result(String id, String text) => fakeExecutedJavaScripts
      .any((s) => s.contains('"$id"') && s.contains(text));
  Future<void> allow(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.text('Allow local diagnostics?'), findsOneWidget);
    await tester.tap(find.text('Allow this document'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'native consent gates persistence and snapshots; workspace change revokes',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'before', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('before', 'error'), true);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    expect(result('configure', '"enabled":true'), true);
    rpc(h, 'append', 'append');
    await tester.pumpAndSettle();
    expect(result('append', '"accepted":1'), true);
    expect(
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey),
        isNot(contains('secret')));
    rpc(h, 'other', 'snapshot', workspace: 'other');
    await tester.pumpAndSettle();
    expect(result('other', 'error'), true);
    rpc(h, 'back', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('back', 'error'), true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'disable revokes access while clear removes evidence without new consent',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    rpc(h, 'off', 'configure', enabled: false);
    await tester.pumpAndSettle();
    expect(result('off', '"enabled":false'), true);
    rpc(h, 'read', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('read', 'error'), true);
    rpc(h, 'clear', 'clear');
    await tester.pumpAndSettle();
    expect(result('clear', '"cleared":true'), true);
    expect(
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey),
        isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('wrong document proof and lock fail closed', (tester) async {
    final h = await start(tester);
    rpc(h, 'wrong', 'configure', token: 'wrong');
    await tester.pumpAndSettle();
    expect(find.text('Allow local diagnostics?'), findsNothing);
    expect(result('wrong', 'error'), true);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    h.config = h.config.copyWith(deviceSecret: '');
    await tester.pumpWidget(h.widget());
    await tester.pumpAndSettle();
    rpc(h, 'locked', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('locked', 'error'), true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('disable while consent is pending cannot reenable after approval',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'pending', 'configure');
    await tester.pumpAndSettle();
    rpc(h, 'off', 'configure', enabled: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow this document'));
    await tester.pumpAndSettle();
    expect(result('pending', 'error'), true);
    rpc(h, 'read', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('read', 'error'), true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'reload requires fresh consent and recovers only matching saved scope',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    rpc(h, 'append', 'append');
    await tester.pumpAndSettle();
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://flightdeck.example',
        isMainFrame: true);
    submitFakePageFinished(
        controllerIndex: 0, url: 'https://flightdeck.example');
    await tester.pumpAndSettle();
    final script = fakeExecutedJavaScripts
        .lastWhere((s) => s.contains('const signerDocumentToken ='));
    h.token = jsonDecode(RegExp(r'const signerDocumentToken = (.*);')
        .firstMatch(script)!
        .group(1)!);
    rpc(h, 'before-reconsent', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('before-reconsent', 'error'), true);
    rpc(h, 'reconfigure', 'configure');
    await allow(tester);
    rpc(h, 'recovered', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('recovered', '"recovered":true'), true);
    expect(result('recovered', '"source":"browser"'), true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'background lifecycle preserves evidence but revokes retrieval consent',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    rpc(h, 'background-read', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('background-read', 'error'), true);
    expect(
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey),
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
  Future<List<dynamic>> savedHostErrors() async {
    final raw =
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as Map)
        .values
        .expand((events) => events as List)
        .where(
            (event) => event['source'] == 'host' && event['level'] == 'error')
        .toList();
  }

  void loadFailure([String url = 'https://flightdeck.example/failed']) {
    submitFakeWebResourceError(
        controllerIndex: 0,
        error: WebResourceError(
            errorCode: -1,
            description: 'untrusted secret body',
            isForMainFrame: true,
            url: url));
  }

  testWidgets(
      'same-origin navigation failure retains native-only transition evidence after revocation',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://flightdeck.example/failed',
        isMainFrame: true);
    loadFailure();
    await tester.pumpAndSettle();
    expect(await savedHostErrors(), hasLength(1));
    expect(
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey),
        isNot(contains('secret')));
    rpc(h, 'revoked', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('revoked', 'error'), true);
    submitFakePageFinished(
        controllerIndex: 0, url: 'https://flightdeck.example');
    await tester.pumpAndSettle();
    final script = fakeExecutedJavaScripts
        .lastWhere((s) => s.contains('const signerDocumentToken ='));
    h.token = jsonDecode(RegExp(r'const signerDocumentToken = (.*);')
        .firstMatch(script)!
        .group(1)!);
    rpc(h, 'reconfigure', 'configure');
    await allow(tester);
    rpc(h, 'recovered', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('recovered', '"recovered":true'), true);
    expect(result('recovered', '"code":"webview"'), true);
    await tester.pumpWidget(const SizedBox());
  });
  for (final revoke in ['disable', 'clear', 'cross-origin', 'lock']) {
    testWidgets('$revoke prevents late transition failure persistence',
        (tester) async {
      final h = await start(tester);
      rpc(h, 'configure', 'configure');
      await allow(tester);
      await submitFakeNavigationRequest(
          controllerIndex: 0,
          url: 'https://flightdeck.example/failed',
          isMainFrame: true);
      if (revoke == 'disable') {
        rpc(h, 'disable', 'configure', enabled: false);
        await tester.pumpAndSettle();
        expect(result('disable', '"enabled":false'), true);
      } else if (revoke == 'clear') {
        rpc(h, 'clear', 'clear');
        await tester.pumpAndSettle();
        expect(result('clear', '"cleared":true'), true);
      }
      if (revoke == 'cross-origin') {
        await submitFakeNavigationRequest(
            controllerIndex: 0,
            url: 'https://other.example/failed',
            isMainFrame: true);
      } else if (revoke == 'lock') {
        h.config = h.config.copyWith(deviceSecret: '');
        await tester.pumpWidget(h.widget());
        await tester.pumpAndSettle();
      }
      loadFailure();
      await tester.pumpAndSettle();
      expect(await savedHostErrors(), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'WebKit content process termination records bounded error and revokes live grant',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    submitFakeWebResourceError(
        controllerIndex: 0,
        error: const WebResourceError(
            errorCode: 2,
            description: 'untrusted description',
            isForMainFrame: true,
            errorType: WebResourceErrorType.webContentProcessTerminated));
    await tester.pumpAndSettle();
    expect(await savedHostErrors(), hasLength(1));
    rpc(h, 'terminated', 'snapshot');
    await tester.pumpAndSettle();
    expect(result('terminated', 'error'), true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expired transition cannot save late load failure',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://flightdeck.example/failed',
        isMainFrame: true);
    await tester.pump(const Duration(seconds: 31));
    loadFailure();
    await tester.pumpAndSettle();
    expect(await savedHostErrors(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'workspace change cancels old transition without granting retrieval',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://flightdeck.example/failed',
        isMainFrame: true);
    rpc(h, 'workspace-change', 'snapshot', workspace: 'other');
    await tester.pumpAndSettle();
    expect(result('workspace-change', 'error'), true);
    loadFailure();
    await tester.pumpAndSettle();
    expect(await savedHostErrors(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('disposed tab cannot save a late native failure', (tester) async {
    final h = await start(tester);
    rpc(h, 'configure', 'configure');
    await allow(tester);
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://flightdeck.example/failed',
        isMainFrame: true);
    await tester.pumpWidget(const SizedBox());
    loadFailure();
    await tester.pumpAndSettle();
    expect(await savedHostErrors(), isEmpty);
  });
  testWidgets('navigation during native consent invalidates original document',
      (tester) async {
    final h = await start(tester);
    rpc(h, 'pending', 'configure');
    await tester.pumpAndSettle();
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://flightdeck.example/new',
        isMainFrame: true);
    await tester.tap(find.text('Allow this document'));
    await tester.pumpAndSettle();
    expect(
        await SharedPreferencesAsync().getString(DiagnosticsStore.storageKey),
        isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
