// Product wiring tests; these do not substitute for native WebView UX evidence.
import 'dart:convert';
import 'dart:async';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'fake_webview_platform.dart';
import 'mesh_auth_signing_test.dart' show Harness, appPage;
import 'grasp_fips_transport_test.dart' show endpoint;

const page = 'https://gitworkshop.example/repository';
const localFlightDeckPage = 'http://127.0.0.1:47831/flightdeck';
Map<String, dynamic> auth([String target = '$endpoint/owner/repo.git']) => {
      'kind': 27235,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'content': '',
      'tags': [
        ['u', target],
        ['method', 'GET']
      ]
    };
Future<String> start(Harness h, WidgetTester tester) async {
  await h.start(tester);
  await submitFakeNavigationRequest(
      controllerIndex: 0, url: page, isMainFrame: true);
  submitFakePageFinished(controllerIndex: 0, url: page);
  await tester.pumpAndSettle();
  final signer = fakeExecutedJavaScripts
      .lastWhere((s) => s.contains('const signerDocumentToken ='));
  h.token = jsonDecode(RegExp(r'const signerDocumentToken = (.*);')
      .firstMatch(signer)!
      .group(1)!);
  final script =
      fakeExecutedJavaScripts.lastWhere((s) => s.contains("'fipsTransport'"));
  expect(script, contains('location.origin !== "https://gitworkshop.example"'));
  expect(script, contains('version:2, available:true'));
  expect(script, contains('async connect(options'));
  expect(
      script,
      contains(
          "window.dispatchEvent(new Event('wingman-fips-transport-ready'))"));
  return RegExp(r'const token = "([^"]+)"').firstMatch(script)!.group(1)!;
}

void rpc(String token, String method, [Map<String, dynamic>? params]) =>
    submitFakeJavaScriptMessage(
        controllerIndex: 0,
        channel: 'WingmanGrasp',
        message: jsonEncode({
          'token': token,
          'id': method,
          'method': method,
          'params': params ?? {'endpoint': endpoint}
        }));
void driveRpc(String token, String id) => submitFakeJavaScriptMessage(
    controllerIndex: 0,
    channel: 'WingmanGrasp',
    message: jsonEncode({
      'token': token,
      'id': id,
      'method': 'connectDrive',
      'params': {'endpoint': endpoint}
    }));
Future<void> connect(String token, WidgetTester tester) async {
  rpc(token, 'connect');
  await tester.pumpAndSettle();
  expect(find.text('Connect to private FIPS service?'), findsOneWidget);
  expect(find.byType(TextField), findsNothing);
  await tester.tap(find.widgetWithText(FilledButton, 'Once').last);
  await tester.pumpAndSettle();
}

Future<void> connectForPurpose(
  String token,
  WidgetTester tester,
  String purpose,
) async {
  rpc(token, 'connect', {
    'endpoint': endpoint,
    'peerNpub': Uri.parse(endpoint).host.replaceFirst('.fips', ''),
    'purpose': purpose,
  });
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Once').last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  testWidgets('off cancels a pending FIPS navigation readiness result',
      (tester) async {
    final runtime = _ToggleBrowserRuntime();
    final pending = Completer<String?>();
    var block = false;
    final h = Harness(
        fipsRuntime: runtime,
        prepareFipsNavigation: (_) async => block ? pending.future : null);
    await start(h, tester);
    block = true;
    final decision = submitFakeNavigationRequest(
        controllerIndex: 0, url: appPage, isMainFrame: true);
    await tester.pump();
    runtime.change(false);
    pending.complete(null);
    expect(await decision, NavigationDecision.prevent);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await runtime.changes.close();
  });

  testWidgets(
      'disabled startup does not programmatically load a FIPS destination',
      (tester) async {
    final runtime = _ToggleBrowserRuntime()..enabled = false;
    final h = Harness(fipsRuntime: runtime, localFlightDeckUrl: appPage);
    await h.start(tester, builtInStartup: true);
    expect(
        fakeLoadedRequestUrls.where((url) => url.contains('.fips')), isEmpty);
    runtime.change(true);
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls.last, appPage);
    await tester.pumpWidget(const SizedBox());
    await runtime.changes.close();
  });

  testWidgets('disabled direct FIPS tab preserves destination and recovers',
      (tester) async {
    final runtime = _ToggleBrowserRuntime();
    final h = Harness(fipsRuntime: runtime);
    await h.start(tester);
    const destination = appPage;
    runtime.change(false);
    await tester.pumpAndSettle();
    expect(fakeLoadedHtmlStrings.last, contains('FIPS disabled'));
    runtime.change(true);
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls.last, destination);
    await tester.pumpWidget(const SizedBox());
    await runtime.changes.close();
  });

  testWidgets(
      'HTTPS signer remains injected after disabling and re-enabling FIPS',
      (tester) async {
    final runtime = _ToggleBrowserRuntime();
    final h = Harness(fipsRuntime: runtime);
    await start(h, tester);
    final oldScript = fakeExecutedJavaScripts
        .lastWhere((s) => s.contains('const signerDocumentToken ='));
    final count = fakeExecutedJavaScripts
        .where((s) => s.contains("'fipsTransport'"))
        .length;
    runtime.change(false);
    await tester.pumpAndSettle();
    final disabledScript = fakeExecutedJavaScripts
        .lastWhere((s) => s.contains('const signerDocumentToken ='));
    expect(disabledScript, isNot(oldScript));
    expect(
        fakeExecutedJavaScripts
            .where((s) => s.contains("'fipsTransport'"))
            .length,
        count);
    expect(fakeLoadedHtmlStrings.where((s) => s.contains('FIPS disabled')),
        isEmpty);
    runtime.change(true);
    await tester.pumpAndSettle();
    expect(
        fakeExecutedJavaScripts
            .where((s) => s.contains("'fipsTransport'"))
            .length,
        greaterThan(count));
    final enabledScript = fakeExecutedJavaScripts
        .lastWhere((s) => s.contains('const signerDocumentToken ='));
    expect(enabledScript, isNot(disabledScript));
    await tester.pumpWidget(const SizedBox());
    await runtime.changes.close();
  });

  testWidgets(
      'native transport consent does not replace exact signature consent',
      (tester) async {
    final h = Harness();
    final token = await start(h, tester);
    h.sign('unapproved', event: auth());
    await tester.pumpAndSettle();
    expect(h.signer.events, isEmpty);
    await connect(token, tester);
    h.sign('other-port',
        event:
            auth('${endpoint.replaceFirst(':8787', ':8788')}/owner/repo.git'));
    await tester.pumpAndSettle();
    expect(h.signer.events, isEmpty);
    h.sign('approved', event: auth());
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsOneWidget);
    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();
    expect(h.signer.events.length, 1);
    rpc(token, 'disconnect');
    await tester.pumpAndSettle();
    h.sign('revoked', event: auth());
    await tester.pumpAndSettle();
    expect(h.signer.events.length, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'transport Always allow is scoped to identity origin endpoint peer and purpose',
      (tester) async {
    final h = Harness();
    final token = await start(h, tester);
    rpc(token, 'connect', {
      'endpoint': endpoint,
      'peerNpub': Uri.parse(endpoint).host.replaceFirst('.fips', ''),
      'purpose': 'autopilot',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Purpose: autopilot'), findsOneWidget);
    await tester.tap(find.text('Always allow'));
    await tester.pumpAndSettle();
    rpc(token, 'disconnect');
    await tester.pumpAndSettle();

    rpc(token, 'connect', {
      'endpoint': endpoint,
      'peerNpub': Uri.parse(endpoint).host.replaceFirst('.fips', ''),
      'purpose': 'autopilot',
    });
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsNothing);
    rpc(token, 'disconnect');
    await tester.pumpAndSettle();

    rpc(token, 'connect', {
      'endpoint': endpoint,
      'peerNpub': Uri.parse(endpoint).host.replaceFirst('.fips', ''),
      'purpose': 'tower',
    });
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'Flight Deck remembers exact Autopilot auth policy but signs every request',
      (tester) async {
    final h = Harness();
    await h.start(tester);
    await submitFakeNavigationRequest(
      controllerIndex: 0,
      url: 'https://flightdeck.example/agents',
      isMainFrame: true,
    );
    submitFakePageFinished(
      controllerIndex: 0,
      url: 'https://flightdeck.example/agents',
    );
    await tester.pumpAndSettle();
    final signerScript = fakeExecutedJavaScripts.lastWhere(
      (script) => script.contains('const signerDocumentToken ='),
    );
    h.token = jsonDecode(
      RegExp(r'const signerDocumentToken = (.*);')
          .firstMatch(signerScript)!
          .group(1)!,
    );
    final bridgeScript = fakeExecutedJavaScripts.lastWhere(
      (script) => script.contains("'fipsTransport'"),
    );
    final bridgeToken = RegExp(
      r'const token = "([^"]+)"',
    ).firstMatch(bridgeScript)!.group(1)!;
    await connectForPurpose(bridgeToken, tester, 'autopilot');

    h.sign(
      'overview',
      method: 'signNip98',
      event: {
        'url': '$endpoint/api/agents/overview',
        'httpMethod': 'GET',
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsOneWidget);
    await tester.tap(find.text('Always allow'));
    await tester.pumpAndSettle();
    expect(h.signer.events, [
      {'url': '$endpoint/api/agents/overview', 'method': 'GET'},
    ]);

    h.sign(
      'pipelines',
      method: 'signNip98',
      event: {
        'url': '$endpoint/api/pipelines',
        'httpMethod': 'GET',
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsNothing);
    expect(h.signer.events, [
      {'url': '$endpoint/api/agents/overview', 'method': 'GET'},
      {'url': '$endpoint/api/pipelines', 'method': 'GET'},
    ]);

    h.sign(
      'post',
      method: 'signNip98',
      event: {
        'url': '$endpoint/api/pipelines',
        'httpMethod': 'POST',
        'body': '{}',
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();

    rpc(bridgeToken, 'disconnect');
    await tester.pumpAndSettle();
    await connectForPurpose(bridgeToken, tester, 'tower');
    h.sign(
      'wrong-purpose',
      method: 'signNip98',
      event: {
        'url': '$endpoint/api/agents/overview',
        'httpMethod': 'GET',
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();

    rpc(bridgeToken, 'disconnect');
    await tester.pumpAndSettle();
    h.sign(
      'revoked',
      method: 'signNip98',
      event: {
        'url': '$endpoint/api/agents/overview',
        'httpMethod': 'GET',
      },
    );
    await tester.pumpAndSettle();
    expect(h.signer.events.length, 2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'public HTTPS auth still uses existing signer policy with GRASP injected',
      (tester) async {
    final h = Harness();
    await start(h, tester);
    h.store.allow = true;
    h.sign('public', event: auth('https://public.example/repo.git'));
    await tester.pumpAndSettle();
    expect(h.signer.events.length, 1);
    expect(find.text('Approve private app authentication?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'local bundled Flight Deck receives Drive-capable GRASP transport',
      (tester) async {
    final h = Harness(localFlightDeckUrl: localFlightDeckPage);
    await h.start(tester);
    await submitFakeNavigationRequest(
        controllerIndex: 0, url: localFlightDeckPage, isMainFrame: true);
    submitFakePageFinished(controllerIndex: 0, url: localFlightDeckPage);
    await tester.pumpAndSettle();
    final script =
        fakeExecutedJavaScripts.lastWhere((s) => s.contains("'fipsTransport'"));
    expect(script, contains('location.origin !== "http://127.0.0.1:47831"'));
    expect(script, contains('connectDrive'));
    expect(script, contains('save:true'));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('same-document Files route keeps Drive consent prompt eligible',
      (tester) async {
    final h = Harness();
    final token = await start(h, tester);
    submitFakeUrlChange(
        controllerIndex: 0, url: 'https://gitworkshop.example/files?tab=drive');
    await tester.pumpAndSettle();
    driveRpc(token, 'drive-after-spa-route');
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Once').last);
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('full navigation revokes old Drive bridge without prompting',
      (tester) async {
    final h = Harness();
    final token = await start(h, tester);
    await submitFakeNavigationRequest(
        controllerIndex: 0,
        url: 'https://gitworkshop.example/other-document',
        isMainFrame: true);
    driveRpc(token, 'old-document-drive');
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cross-origin URL callback revokes old Drive bridge',
      (tester) async {
    final h = Harness();
    final token = await start(h, tester);
    submitFakeUrlChange(controllerIndex: 0, url: 'https://other.example/files');
    await tester.pumpAndSettle();
    driveRpc(token, 'old-origin-drive');
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('explicit Drive denial remains remembered for the document',
      (tester) async {
    final h = Harness();
    final token = await start(h, tester);
    driveRpc(token, 'first-drive');
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();
    driveRpc(token, 'second-drive');
    await tester.pumpAndSettle();
    expect(find.text('Connect to private FIPS service?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  for (final reason in [
    'navigation',
    'identity',
    'lock',
    'tab-close',
    'disconnect-reconnect'
  ]) {
    testWidgets('pending GRASP signature invalidated by $reason',
        (tester) async {
      final h = Harness();
      final token = await start(h, tester);
      await connect(token, tester);
      h.sign('pending', event: auth());
      await tester.pumpAndSettle();
      expect(find.text('Approve private app authentication?'), findsOneWidget);
      if (reason == 'navigation') {
        await submitFakeNavigationRequest(
            controllerIndex: 0, url: page, isMainFrame: true);
      } else if (reason == 'identity' || reason == 'lock') {
        h.config = reason == 'identity'
            ? h.config.copyWith(deviceNpub: 'other')
            : h.config.copyWith(deviceSecret: '');
        await tester.pumpWidget(h.widget());
      } else if (reason == 'tab-close') {
        await tester.pumpWidget(const SizedBox());
        return;
      } else {
        rpc(token, 'disconnect');
        await tester.pumpAndSettle();
        // Reconnect's native dialog stacks above the old signature dialog.
        await connect(token, tester);
      }
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      expect(h.signer.events, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _ToggleBrowserRuntime extends FipsRuntimeService {
  bool enabled = true;
  final changes = StreamController<bool>.broadcast(sync: true);
  @override
  Future<bool> get isEnabled async => enabled;
  @override
  Stream<bool> get enabledChanges => changes.stream;
  void change(bool value) {
    enabled = value;
    changes.add(value);
  }
}
