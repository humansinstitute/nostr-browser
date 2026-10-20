import 'pin_input_test_helpers.dart';
import 'package:wingman_app/src/widgets/immediate_pin_field.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/app.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/core/signer_vault.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_relay_client.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_store.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';

import 'fake_webview_platform.dart';

class ObservedVault extends SignerVault {
  ObservedVault()
      : super(
            localStore: MemorySignerVaultLocalStore(),
            secretStore: MemorySignerVaultSecretStore());
  Future<SignerVaultUnlock>? pending;
  @override
  Future<SignerVaultUnlock> create(
          {required String nsec, required String pin}) =>
      pending = super.create(nsec: nsec, pin: pin);
  @override
  Future<SignerVaultUnlock> unlock({required String pin}) =>
      pending = super.unlock(pin: pin);
}

class FakeProfileRelays extends NostrProfileRelayClient {
  FakeProfileRelays() : super(relays: []);
  final refresh = Completer<NostrProfileRelayResult?>();
  final events = <Map<String, dynamic>>[];
  bool accept = false;
  @override
  Future<NostrProfileRelayResult?> fetchProfile(String publicKeyHex) =>
      refresh.future;
  @override
  Future<ProfilePublishResult> publish(Map<String, dynamic> event) async {
    events.add(event);
    return ProfilePublishResult(
        acceptedRelays: accept ? ['ws://fake.test'] : [], totalRelays: 1);
  }
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
  });
  Finder field(String label) => find.byWidgetPredicate((widget) =>
      (widget is TextField && widget.decoration?.labelText == label) ||
      (widget is ImmediatePinField && widget.decoration.labelText == label));
  Future<void> openAvatar(WidgetTester tester, String action) async {
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  Future<void> submit(
      WidgetTester tester, String label, ObservedVault vault) async {
    await tester.scrollUntilVisible(find.text(label), 150,
        scrollable: find.byType(Scrollable).last);
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await vault.pending;
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
      'saved vault gates starred startup tabs and same identity unlock preserves them',
      (tester) async {
    final vault = ObservedVault();
    late SignerVaultUnlock identity;
    await tester.runAsync(() async {
      identity = await vault.create(nsec: '1'.padLeft(64, '0'), pin: '1234');
    });
    final prefs = SharedPreferencesAsync();
    final tabsKey = 'wingman.browser.tabs.v1.${identity.npub}';
    final snapshot = jsonEncode({
      'version': 2,
      'active_index': 1,
      'tabs': [
        {
          'title': 'deck.test',
          'url': 'https://deck.test',
          'is_home': false,
          'diagnostics_tab_key': 'A' * 43
        },
        {
          'title': 'other.test',
          'url': 'https://other.test',
          'is_home': false,
          'diagnostics_tab_key': 'B' * 43
        },
      ]
    });
    await prefs.setString('wingman.browser.last_signer_npub.v1', identity.npub);
    await prefs.setString(tabsKey, snapshot);
    await BrowserBookmarkStore().save(identity.npub, const [
      BrowserBookmark(
          title: 'deck.test', url: 'https://deck.test', startup: true),
      BrowserBookmark(
          title: 'other.test', url: 'https://other.test', startup: true),
    ]);
    await tester.pumpWidget(WingmanApp(
        signerVault: vault, profileRelayClient: FakeProfileRelays()));
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.byType(BrowserScreen), findsNothing);
    expect(fakeWebViewControllerCreationCount, 0);
    expect(await prefs.getString(tabsKey), snapshot);
    await enterEditorText(tester, field('PIN'), '1234');
    await submit(tester, 'Unlock', vault);
    expect(fakeLoadedRequestUrls,
        containsAll(['https://deck.test', 'https://other.test']));
    expect(fakeClearCookieCalls, 0);
    final browser = tester.widget<BrowserScreen>(find.byType(BrowserScreen));
    expect(
        (await browser.bridge.signEvent(
                config: browser.config,
                event: {'kind': 1, 'content': 'fixture', 'tags': []}))
            .ok,
        isTrue);
    final controllers = fakeWebViewControllerCreationCount;
    await openAvatar(tester, 'Log out');
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();
    final locked = tester.widget<BrowserScreen>(find.byType(BrowserScreen));
    expect(
        (await locked.bridge.signNip98(
                config: locked.config, method: 'GET', url: 'https://deck.test'))
            .error,
        NativeCoreBridge.signerLockedError);
    for (final method in ['signEvent', 'signNip98']) {
      submitFakeJavaScriptMessage(
          controllerIndex: controllers - 1,
          channel: 'WingmanSigner',
          message: jsonEncode({'id': method, 'method': method, 'params': {}}));
      await tester.pumpAndSettle();
      expect(fakeExecutedJavaScripts.last, contains('Signer is locked'));
    }
    await openAvatar(tester, 'Unlock identity');
    await enterEditorText(tester, field('PIN'), '1234');
    await submit(tester, 'Unlock', vault);
    expect(fakeWebViewControllerCreationCount, controllers);
    expect(fakeReloadCalls, 2);
    expect(fakeClearCookieCalls, 0);
    final recovered = tester.widget<BrowserScreen>(find.byType(BrowserScreen));
    expect(
        (await recovered.bridge.signNip98(
                config: recovered.config,
                method: 'GET',
                url: 'https://deck.test'))
            .ok,
        isTrue);
    expect((jsonDecode((await prefs.getString(tabsKey))!) as Map)['tabs'],
        (jsonDecode(snapshot) as Map)['tabs']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets(
        'avatar create, cancel, profile setup and vault unlock at $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final vault = ObservedVault();
      final relays = FakeProfileRelays();
      await tester.pumpWidget(
          WingmanApp(signerVault: vault, profileRelayClient: relays));
      await tester.pumpAndSettle();
      await openAvatar(tester, 'Create identity / Import key');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(await vault.loadRecord(), isNull);
      await openAvatar(tester, 'Create identity / Import key');
      await enterEditorText(tester, field('PIN'), '1234');
      await enterEditorText(tester, field('Confirm PIN'), '1234');
      await submit(tester, 'Create and encrypt identity', vault);
      final record = await vault.loadRecord();
      expect(record, isNotNull);
      expect(find.text('Edit profile'), findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(const ValueKey('profile-npub'))).data,
          '${record!.npub.substring(0, 10)}…${record.npub.substring(record.npub.length - 5)}');
      expect(find.byTooltip('Copy npub'), findsOneWidget);
      expect(find.byTooltip('Upload image'), findsOneWidget);
      expect(find.text('Export private key (nsec)'), findsOneWidget);
      expect(find.text('Sign and publish'), findsNothing);
      expect(
          tester.getBottomLeft(find.widgetWithText(FilledButton, 'Save')).dy -
              tester.getTopLeft(find.text('Edit profile')).dy,
          lessThan(620));
      relays.accept = true;
      await enterEditorText(tester, field('Display name'), 'New User');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect((await NostrProfileStore().load(record.npub)).displayName,
          'New User');
      expect(relays.events, hasLength(1));
      await openAvatar(tester, 'Log out');
      await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
      await tester.pumpAndSettle();
      await openAvatar(tester, 'Unlock identity');
      expect(find.text('Create identity'), findsNothing);
      await tester.tap(find.text('Reset local signer vault'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await vault.loadRecord())!.npub, record.npub);
      await enterEditorText(tester, field('PIN'), '1234');
      await submit(tester, 'Unlock', vault);
      await tester.tap(find.byTooltip('Profile'));
      await tester.pumpAndSettle();
      expect(find.text('New User'), findsOneWidget);
      expect(find.text('Edit profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('import remains usable and invalid private input is never echoed',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final vault = ObservedVault();
    await tester.pumpWidget(WingmanApp(
        signerVault: vault, profileRelayClient: FakeProfileRelays()));
    await tester.pumpAndSettle();
    await openAvatar(tester, 'Create identity / Import key');
    await tester.tap(find.text('Import key'));
    await tester.pumpAndSettle();
    await enterEditorText(
        tester, field('Nostr private key'), 'nsec-private-invalid-input');
    await enterEditorText(tester, field('PIN'), '1234');
    await enterEditorText(tester, field('Confirm PIN'), '1234');
    // The error is handled by the screen; consume the same failing future here.
    await tester.runAsync(() async {
      await tester.tap(find.text('Encrypt and Continue'));
      try {
        await vault.pending;
      } catch (_) {}
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Unable to open the signer'), findsOneWidget);
    expect(await vault.loadRecord(), isNull);
    final identity = NostrCrypto.importIdentity('3'.padLeft(64, '0'));
    await enterEditorText(tester, field('Nostr private key'), identity.nsec);
    await submit(tester, 'Encrypt and Continue', vault);
    expect((await vault.loadRecord())!.npub, identity.npub);
    expect(find.text('Edit profile'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'publication failure retains draft, retries, and delayed refresh cannot clobber edit',
      (tester) async {
    final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
    final relays = FakeProfileRelays();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BrowserScreen(
      config: AppConfig.defaults().copyWith(
          deviceNpub: identity.npub,
          devicePublicKeyHex: identity.publicKeyHex,
          deviceSecret: identity.nsec),
      bridge: NativeCoreBridge(),
      signerStore: SignerStore(),
      profileRelayClient: relays,
      onOpenDrawer: () {},
      onOpenSetup: () {},
      onOpenSigner: () {},
      onOpenStatus: () {},
    ))));
    await tester.pumpAndSettle();
    await openAvatar(tester, 'Edit profile');
    await enterEditorText(tester, field('Display name'), 'Local draft');
    relays.refresh.complete(const NostrProfileRelayResult(
        profile: NostrProfile(displayName: 'Stale remote'), createdAt: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not publish.'), findsOneWidget);
    expect((await NostrProfileStore().load(identity.npub)).displayName,
        'Local draft');
    expect(relays.events.single['pubkey'], identity.publicKeyHex);
    relays.accept = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Profile saved.'), findsOneWidget);
    expect(relays.events, hasLength(2));
    expect(find.byType(AlertDialog), findsNothing);
    await openAvatar(tester, 'Edit profile');
    expect(tester.widget<TextField>(field('Display name')).controller!.text,
        'Local draft');
    await enterEditorText(tester, field('Display name'), 'Cancelled edit');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await NostrProfileStore().load(identity.npub)).displayName,
        'Local draft');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
      'late refresh from another identity changes neither UI nor its stored draft',
      (tester) async {
    final first = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
    final second = NostrCrypto.importIdentity('2'.padLeft(64, '0'));
    final relays = FakeProfileRelays();
    final store = NostrProfileStore();
    await store.save(
        first.npub, const NostrProfile(displayName: 'First draft'));
    await store.save(
        second.npub, const NostrProfile(displayName: 'Second draft'));
    Widget browser(NostrIdentity identity) => MaterialApp(
            home: Scaffold(
                body: BrowserScreen(
          config: AppConfig.defaults().copyWith(
              deviceNpub: identity.npub,
              devicePublicKeyHex: identity.publicKeyHex,
              deviceSecret: identity.nsec),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          profileRelayClient: relays,
          onOpenDrawer: () {},
          onOpenSetup: () {},
          onOpenSigner: () {},
          onOpenStatus: () {},
        )));
    await tester.pumpWidget(browser(first));
    await tester.pumpAndSettle();
    await tester.pumpWidget(browser(second));
    await tester.pumpAndSettle();
    relays.refresh.complete(const NostrProfileRelayResult(
        profile: NostrProfile(displayName: 'Late result'), createdAt: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Second draft'), findsOneWidget);
    expect(find.text('First draft'), findsNothing);
    expect(find.text('Late result'), findsNothing);
    expect((await store.load(first.npub)).displayName, 'First draft');
    expect((await store.load(second.npub)).displayName, 'Second draft');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
