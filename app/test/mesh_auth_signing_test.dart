import 'dart:async';
import 'dart:convert';
import 'package:bip340/bip340.dart' as bip340;
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'package:wingman_app/src/core/signer_vault.dart';
import 'fake_webview_platform.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_relay_client.dart';
import 'mesh_auth_request_test.dart'
    show node, httpTarget, relayTarget, authEvent;

const appPage = 'http://$node.fips:41023/';
const exactError =
    'fips_signing_scope_required: An active exact FIPS service grant is required for signing.';

class AuthSigner extends NativeCoreBridge {
  final events = <Map<String, dynamic>>[];
  Completer<void>? gate;
  @override
  Future<CoreCommandResult> signEvent({
    required AppConfig config,
    required Map<String, dynamic> event,
  }) async {
    events.add(event);
    await gate?.future;
    return const CoreCommandResult(
      ok: true,
      json: {'signature': 'test-signature'},
    );
  }

  @override
  Future<CoreCommandResult> signNip98({
    required AppConfig config,
    required String url,
    required String method,
    String? body,
  }) async {
    events.add({'url': url, 'method': method});
    await gate?.future;
    return const CoreCommandResult(
      ok: true,
      json: {'authorization': 'test-authorization'},
    );
  }
}

class AuthStore extends SignerStore {
  bool deny = false;
  bool allow = false;
  @override
  Future<SignerPolicyRule?> findPolicyRule({
    required String pageOrigin,
    required String operation,
    required String target,
    required String deviceNpub,
  }) async {
    if (!deny && !allow) {
      return super.findPolicyRule(
        pageOrigin: pageOrigin,
        operation: operation,
        target: target,
        deviceNpub: deviceNpub,
      );
    }
    return SignerPolicyRule(
      pageOrigin: pageOrigin,
      operation: operation,
      target: target,
      deviceNpub: deviceNpub,
      decision:
          deny ? SignerPolicyRuleDecision.deny : SignerPolicyRuleDecision.allow,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> appendAudit(SignerAuditEntry entry) async {}
}

class Harness {
  Harness({
    this.realBridge,
    this.fipsRuntime,
    this.prepareFipsNavigation,
    this.signerVault,
    this.localFlightDeckUrl = 'https://flightdeck.example',
  });
  final NativeCoreBridge? realBridge;
  final FipsRuntimeService? fipsRuntime;
  final Future<String?> Function(String)? prepareFipsNavigation;
  final SignerVault? signerVault;
  final String localFlightDeckUrl;
  final signer = AuthSigner();
  final store = AuthStore();
  final key = GlobalKey<BrowserScreenState>();
  var config = AppConfig.defaults().copyWith(
    towerUrl: '',
    flightDeckUrl: 'https://flightdeck.example',
    deviceNpub: 'test-identity',
    deviceSecret: 'non-key-test-placeholder',
  );
  String? token;
  Widget widget() => MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            key: key,
            config: config,
            bridge: realBridge ?? signer,
            signerStore: store,
            profileRelayClient: NostrProfileRelayClient(relays: const []),
            localFlightDeckUrl: localFlightDeckUrl,
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
            signerVault: signerVault,
            fipsRuntime: fipsRuntime,
            onPrepareFipsNavigation: prepareFipsNavigation ?? (_) async => null,
          ),
        ),
      );
  Future<void> start(WidgetTester tester, {bool builtInStartup = false}) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await SharedPreferencesAsync().setString(
      'wingman.browser.last_signer_npub.v1',
      config.deviceNpub,
    );
    await BrowserBookmarkStore()
        .saveBuiltInStartup(config.deviceNpub, builtInStartup);
    installFakeWebViewPlatform();
    await tester.pumpWidget(widget());
    await tester.pumpAndSettle();
    submitFakePageFinished(controllerIndex: 0, url: appPage);
    await tester.pumpAndSettle();
    final script = fakeExecutedJavaScripts.lastWhere(
      (s) => s.contains('const signerDocumentToken ='),
    );
    token = jsonDecode(
      RegExp(
        r'const signerDocumentToken = (.*);',
      ).firstMatch(script)!.group(1)!,
    );
    expect(script, contains('window !== window.top'));
  }

  void sign(
    String id, {
    Map<String, dynamic>? event,
    String method = 'signEvent',
    String? proof,
    bool missingProof = false,
  }) {
    submitFakeJavaScriptMessage(
      controllerIndex: 0,
      channel: 'WingmanSigner',
      message: jsonEncode({
        'id': id,
        'method': method,
        'signerDocumentToken': missingProof ? null : proof ?? token,
        'params': event ?? authEvent(),
      }),
    );
  }
}

class UnlockCountingVault extends SignerVault {
  UnlockCountingVault()
      : super(
          localStore: MemorySignerVaultLocalStore(),
          secretStore: MemorySignerVaultSecretStore(),
        );

  @override
  Future<SignerVaultUnlock> unlock({required String pin}) async {
    unlockCalls += 1;
    throw StateError('Browser signing must not unlock the signer vault.');
  }

  int unlockCalls = 0;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  testWidgets(
    'exact Tower error reproduced; cross-port HTTP and relay require separate approval',
    (tester) async {
      final h = Harness();
      await h.start(tester);
      h.sign('old', missingProof: true);
      await tester.pumpAndSettle();
      expect(fakeExecutedJavaScripts.last, contains(exactError));
      expect(h.signer.events, isEmpty);
      h.sign('forged', proof: 'wrong');
      await tester.pumpAndSettle();
      expect(h.signer.events, isEmpty);
      for (final relay in [false, true]) {
        h.sign('allowed-$relay', event: authEvent(relay: relay));
        await tester.pumpAndSettle();
        expect(
          find.text('Approve private app authentication?'),
          findsOneWidget,
        );
        expect(find.text(relay ? relayTarget : httpTarget), findsOneWidget);
        expect(
          find.text(appPage.substring(0, appPage.length - 1)),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text('Once'));
        await tester.pumpAndSettle();
        expect(h.signer.events.length, relay ? 2 : 1);
        expect(h.signer.events.last, authEvent(relay: relay));
      }
      h.sign(
        'other',
        event: authEvent(target: httpTarget.replaceFirst(':41007', ':41008')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Approve private app authentication?'), findsOneWidget);
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(h.signer.events.length, 2);
      expect(fakeExecutedJavaScripts.last, contains('denied'));
      h.store.deny = true;
      h.sign('policy-deny');
      await tester.pumpAndSettle();
      expect(find.text('Approve private app authentication?'), findsNothing);
      expect(h.signer.events.length, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('signNip98 approves exact target without config allowlist', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester);
    h.sign(
      'nip98',
      method: 'signNip98',
      event: {'url': httpTarget, 'httpMethod': 'GET'},
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();
    expect(h.signer.events.single, {'url': httpTarget, 'method': 'GET'});
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Flight Deck boot and signing do not unlock signer vault', (
    tester,
  ) async {
    final vault = UnlockCountingVault();
    final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
    final h = Harness(localFlightDeckUrl: appPage, signerVault: vault)
      ..config = AppConfig.defaults().copyWith(
        flightDeckUrl: 'https://flightdeck.example',
        deviceNpub: identity.npub,
        devicePublicKeyHex: identity.publicKeyHex,
        deviceSecret: identity.nsec,
      );
    h.store.allow = true;
    await h.start(tester);
    expect(vault.unlockCalls, 0);

    h.sign(
      'flight-deck-nip98',
      method: 'signNip98',
      event: {'url': appPage, 'httpMethod': 'GET'},
    );
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(h.signer.events.single, {'url': appPage, 'method': 'GET'});
    expect(vault.unlockCalls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  for (final reason in [
    'navigation',
    'same-url',
    'identity',
    'logout',
    'configuration',
    'clear-data',
  ]) {
    testWidgets('pending exact approval revoked by $reason', (tester) async {
      final h = Harness();
      await h.start(tester);
      h.sign('pending');
      await tester.pumpAndSettle();
      expect(find.text('Approve private app authentication?'), findsOneWidget);
      if (reason == 'navigation' || reason == 'same-url') {
        await submitFakeNavigationRequest(
          controllerIndex: 0,
          url: reason == 'same-url' ? appPage : 'https://other.example',
          isMainFrame: true,
        );
      } else if (reason == 'clear-data') {
        await h.key.currentState!.clearBrowserData();
      } else {
        h.config = reason == 'identity'
            ? h.config.copyWith(deviceNpub: 'other-identity')
            : reason == 'logout'
                ? h.config.copyWith(deviceSecret: '')
                : h.config.copyWith(towerUrl: 'https://other-tower.example');
        await tester.pumpWidget(h.widget());
      }
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      expect(h.signer.events, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('navigation during native signature prevents result delivery', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester);
    h.signer.gate = Completer<void>();
    h.sign('native-pending');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();
    expect(h.signer.events.length, 1);
    await submitFakeNavigationRequest(
      controllerIndex: 0,
      url: appPage,
      isMainFrame: true,
    );
    h.signer.gate!.complete();
    await tester.pumpAndSettle();
    expect(
      fakeExecutedJavaScripts.where((s) => s.contains('test-signature')),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'malformed auth cannot fall through remembered generic kind allow',
    (tester) async {
      final h = Harness();
      await h.start(tester);
      final duplicate = authEvent();
      (duplicate['tags'] as List).add([
        'u',
        httpTarget.replaceFirst(':41007', ':41008'),
      ]);
      for (final event in [
        duplicate,
        {...authEvent(), 'kind': '27235'},
        {...authEvent(), 'tags': []},
        {...authEvent(), 'content': 'unexpected'},
        authEvent(target: 'https://public.example/repo'),
      ]) {
        h.sign('malformed', event: event);
        await tester.pumpAndSettle();
        expect(find.text('Approve private app authentication?'), findsNothing);
        expect(h.signer.events, isEmpty);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('background tab cannot request or finish native approval', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester);
    h.sign('pending');
    await tester.pumpAndSettle();
    h.sign(
      'new-tab',
      method: 'openTab',
      event: {'url': 'https://other.example'},
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Once'));
    await tester.pumpAndSettle();
    expect(h.signer.events, isEmpty);
    h.sign('background');
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsNothing);
    expect(h.signer.events, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'identity change during native signature prevents result delivery',
    (tester) async {
      final h = Harness();
      await h.start(tester);
      h.signer.gate = Completer<void>();
      h.sign('native-pending');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      expect(h.signer.events.length, 1);
      h.config = h.config.copyWith(deviceNpub: 'other-identity');
      await tester.pumpWidget(h.widget());
      h.signer.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        fakeExecutedJavaScripts.where((s) => s.contains('test-signature')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'approved HTTP and relay requests use real native cryptographic signer',
    (tester) async {
      final identity = NostrCrypto.generateIdentity();
      final h = Harness(realBridge: NativeCoreBridge());
      h.config = h.config.copyWith(
        deviceNpub: identity.npub,
        deviceSecret: identity.nsec,
      );
      await h.start(tester);
      for (final relay in [false, true]) {
        final event = authEvent(relay: relay);
        h.sign('real', event: event);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Once'));
        await tester.pumpAndSettle();
        final reply = fakeExecutedJavaScripts.lastWhere(
          (s) => s.startsWith(
            'window.__wingmanResolve && window.__wingmanResolve("real",',
          ),
        );
        final payload = jsonDecode(
          reply.substring(reply.indexOf(', ') + 2, reply.length - 2),
        ) as Map<String, dynamic>;
        final signed = payload['result'] as Map<String, dynamic>;
        expect(signed['pubkey'], identity.publicKeyHex);
        expect(signed['kind'], event['kind']);
        expect(signed['tags'], event['tags']);
        expect(
          bip340.verify(
            signed['pubkey'] as String,
            signed['id'] as String,
            signed['sig'] as String,
          ),
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('configured Tower page cannot use direct WApp fallback', (
    tester,
  ) async {
    final h = Harness();
    h.config = h.config.copyWith(flightDeckUrl: appPage);
    await h.start(tester);
    h.sign('tower-bypass');
    await tester.pumpAndSettle();
    expect(find.text('Approve private app authentication?'), findsNothing);
    expect(h.signer.events, isEmpty);
    expect(fakeExecutedJavaScripts.last, contains(exactError));
    await tester.pumpWidget(const SizedBox());
  });
}
