import 'dart:async';
import 'dart:convert';
import 'package:wingman_app/src/app.dart';
import 'package:wingman_app/src/core/signer_vault.dart';
import 'package:wingman_app/src/widgets/immediate_pin_field.dart';
import 'pin_input_test_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'fake_webview_platform.dart';

const builtIn = 'http://127.0.0.1:47831/';
const first = 'https://first.example/long?keep=1#part';
const second = 'https://second.example/';

final class _DelayedPreferences extends InMemorySharedPreferencesAsync {
  _DelayedPreferences() : super.empty();
  final reads = <Completer<void>>[];
  bool delay = false;
  @override
  Future<String?> getString(
      String key, SharedPreferencesOptions options) async {
    final value = await super.getString(key, options);
    if (delay && key == '${BrowserBookmarkStore.keyPrefix}npub-a') {
      final gate = Completer<void>();
      reads.add(gate);
      await gate.future;
    }
    return value;
  }
}

final class _RecoveryVault extends SignerVault {
  int unlocks = 0;
  @override
  Future<SignerVaultRecord?> loadRecord() async => SignerVaultRecord(
      version: 1,
      kdf: '',
      iterations: 1,
      salt: '',
      nonce: '',
      ciphertext: '',
      mac: '',
      npub: 'npub-a',
      publicKeyHex: '',
      createdAt: DateTime(2026));
  @override
  Future<SignerVaultUnlock> unlock({required String pin}) async {
    unlocks++;
    if (pin != '1234') throw const SignerVaultException('Incorrect PIN.');
    return const SignerVaultUnlock(
        nsec: 'fixture-secret', npub: 'npub-a', publicKeyHex: '');
  }
}

final class _SlowTabsPreferences extends InMemorySharedPreferencesAsync {
  _SlowTabsPreferences() : super.empty();
  Completer<void>? writeGate;
  Completer<void>? readGate;
  @override
  Future<bool> setString(
      String key, String value, SharedPreferencesOptions options) async {
    if (key.startsWith('wingman.browser.tabs.v3.')) await writeGate?.future;
    return super.setString(key, value, options);
  }

  @override
  Future<String?> getString(
      String key, SharedPreferencesOptions options) async {
    final raw = await super.getString(key, options);
    if (key == 'wingman.browser.tabs.v3.npub-a') await readGate?.future;
    return raw;
  }
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
  });
  Widget browser(String identity,
          {GlobalKey<BrowserScreenState>? key, String secret = ''}) =>
      MaterialApp(
          home: Scaffold(
              body: BrowserScreen(
                  key: key,
                  config: AppConfig.defaults()
                      .copyWith(deviceNpub: identity, deviceSecret: secret),
                  bridge: NativeCoreBridge(),
                  signerStore: SignerStore(),
                  onOpenDrawer: () {},
                  onOpenSetup: () {},
                  onOpenSigner: () {},
                  onOpenStatus: () {})));
  void send(int controller, String method, Map<String, dynamic> params) =>
      submitFakeJavaScriptMessage(
          controllerIndex: controller,
          channel: 'WingmanSigner',
          message: jsonEncode(
              {'id': 'test-$method', 'method': method, 'params': params}));
  Future<void> seed({int stars = 0, bool builtInStar = false}) async {
    final store = BrowserBookmarkStore();
    await store.save('npub-a', [
      BrowserBookmark(title: 'First', url: first, startup: stars > 0),
      BrowserBookmark(title: 'Second', url: second, startup: stars > 1),
    ]);
    await store.saveBuiltInStartup('npub-a', builtInStar);
  }

  for (final count in [0, 1, 2]) {
    testWidgets(
        '$count startup stars open exactly once per fresh session despite old snapshots',
        (tester) async {
      await seed(stars: count);
      final preferences = SharedPreferencesAsync();
      const legacy =
          '{"version":2,"active_index":0,"tabs":[{"url":"http://127.0.0.1:47831/","is_home":false}]}';
      await preferences.setString('wingman.browser.tabs.v1.npub-a', legacy);
      for (var launch = 0; launch < 2; launch++) {
        installFakeWebViewPlatform();
        await tester.pumpWidget(browser('npub-a'));
        await tester.pumpAndSettle();
        expect(fakeLoadedRequestUrls,
            [if (count > 0) first, if (count > 1) second]);
        expect(
            find.text('New Tab'), count == 0 ? findsOneWidget : findsNothing);
        expect(await preferences.getString('wingman.browser.tabs.v1.npub-a'),
            legacy);
        await tester.pump(const Duration(seconds: 2));
        expect(fakeLoadedRequestUrls.length, count);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
      'obsolete built-in stars and saved slots never launch; external app survives',
      (tester) async {
    await seed(stars: 2, builtInStar: true);
    final store = BrowserBookmarkStore();
    await store.save('npub-a', [
      ...await store.load('npub-a'),
      const BrowserBookmark(title: 'Old slot', url: builtIn, startup: true),
      const BrowserBookmark(
          title: 'Flight Deck', url: 'https://deck.example/', startup: true),
    ]);
    for (var launch = 0; launch < 2; launch++) {
      installFakeWebViewPlatform();
      await tester.pumpWidget(browser('npub-a'));
      await tester.pumpAndSettle();
      expect(fakeLoadedRequestUrls, [first, second, 'https://deck.example/']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    // Migration is a read filter; the original user data remains recoverable.
    expect(await store.loadBuiltInStartup('npub-a'), isTrue);
    expect(
        await SharedPreferencesAsync()
            .getString('${BrowserBookmarkStore.keyPrefix}npub-a'),
        contains(builtIn));
  });

  Future<void> snapshot(String identity, List<Map<String, dynamic>> tabs,
          {int active = 0}) =>
      SharedPreferencesAsync().setString('wingman.browser.tabs.v3.$identity',
          jsonEncode({'version': 3, 'active_index': active, 'tabs': tabs}));

  testWidgets(
      'cold relaunch restores order titles active tab and home before stars',
      (tester) async {
    await seed(stars: 1);
    await snapshot(
        'npub-a',
        [
          {'is_home': false, 'url': second, 'title': 'Working second'},
          {'is_home': true, 'url': null, 'title': 'New Tab'},
          {'is_home': false, 'url': first, 'title': 'Working first'},
        ],
        active: 2);
    for (var launch = 0; launch < 2; launch++) {
      installFakeWebViewPlatform();
      fakeFinishRequests = false;
      await tester.pumpWidget(browser('npub-a'));
      await tester.pumpAndSettle();
      expect(find.text('Working second'), findsOneWidget);
      expect(find.text('Working first'), findsOneWidget);
      expect(fakeLoadedRequestUrls, [second, first]);
      expect(
          tester.widgetList<IndexedStack>(find.byType(IndexedStack)).last.index,
          2);
      expect(find.text('New Tab'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      'closing last window persists deliberate home instead of startup stars',
      (tester) async {
    await seed(stars: 1);
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close tab'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    installFakeWebViewPlatform();
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(find.text('New Tab'), findsOneWidget);
  });

  testWidgets(
      'same identity lock and PIN unlock keep controllers windows and active tab',
      (tester) async {
    final key = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(browser('npub-a', key: key, secret: 'test-secret'));
    await tester.pumpAndSettle();
    key.currentState!.openTab(first);
    key.currentState!.openTab(second);
    await tester.pumpAndSettle();
    final controllers = fakeWebViewControllerCreationCount;
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    expect(fakeReloadCalls, 0);
    await tester.pumpWidget(browser('npub-a', key: key, secret: 'test-secret'));
    await tester.pumpAndSettle();
    expect(fakeWebViewControllerCreationCount, controllers);
    expect(fakeReloadCalls, 2);
    expect(
        tester.widgetList<IndexedStack>(find.byType(IndexedStack)).last.index,
        2);
  });

  testWidgets('rapid navigation and immediate recreate recover newest state',
      (tester) async {
    final key = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    key.currentState!.openTab(first);
    await tester.pumpAndSettle();
    submitFakeUrlChange(controllerIndex: 1, url: second);
    await tester.pumpWidget(const SizedBox.shrink());
    // Do not wait for a persistence debounce or drain disk operations.
    installFakeWebViewPlatform();
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [second]);
  });

  for (final raw in [
    '{broken',
    '{"version":99,"active_index":0,"tabs":[]}',
    '{"version":3,"active_index":0,"tabs":[]}',
    '{"version":3,"active_index":"bad","tabs":[{}]}',
    '{"version":3,"active_index":0,"tabs":[{"is_home":false,"url":"javascript:alert(1)"}]}',
    '{"version":3,"active_index":0,"tabs":[{"is_home":false,"url":"https://example.test/","title":42}]}',
  ]) {
    testWidgets('corrupt snapshot falls back safely: $raw', (tester) async {
      await seed(stars: 1);
      await SharedPreferencesAsync()
          .setString('wingman.browser.tabs.v3.npub-a', raw);
      await tester.pumpWidget(browser('npub-a'));
      await tester.pumpAndSettle();
      expect(fakeLoadedRequestUrls, [first]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cold identity isolation and out of range active index',
      (tester) async {
    await snapshot(
        'npub-a',
        [
          {'is_home': false, 'url': first}
        ],
        active: 99);
    await snapshot(
        'npub-b',
        [
          {'is_home': false, 'url': second}
        ],
        active: -1);
    await tester.pumpWidget(browser('npub-b'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [second]);
    expect(
        tester.widgetList<IndexedStack>(find.byType(IndexedStack)).last.index,
        0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    installFakeWebViewPlatform();
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [first]);
  });

  testWidgets(
      'rapid settings saves update every home without reload or immediate launch',
      (tester) async {
    await seed();
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    final home = fakeWebViewControllerCreationCount - 1;
    final htmlCount = fakeLoadedHtmlStrings.length;
    send(home, 'setStartup', {'url': first, 'enabled': true});
    send(home, 'setStartup', {'url': second, 'enabled': true});
    send(home, 'setLabelColour', {'colour': '#ffcc88'});
    await tester.pumpAndSettle();
    expect(
        (await BrowserBookmarkStore().load('npub-a'))
            .every((app) => app.startup),
        isTrue);
    expect(await BrowserBookmarkStore().loadLabelColour('npub-a'), '#ffcc88');
    expect(fakeLoadedHtmlStrings.length, htmlCount);
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(
        fakeExecutedJavaScripts
            .where((s) => s.contains('el.style.color'))
            .length,
        6);
    // Reloading the home and metadata refresh never runs startup again.
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    await tester.tap(find.byTooltip('Reload'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    send(home, 'navigateTab', {'url': first});
    await tester.pumpAndSettle();
    send(home, 'bookmarkIcon',
        {'url': first, 'iconUrl': 'https://first.example/icon.png'});
    await tester.pumpAndSettle();
    expect((await BrowserBookmarkStore().load('npub-a')).first.startup, isTrue);
    // Removing via another launcher also removes the startup choice.
    send(0, 'removeBookmark', {'url': first});
    await tester.pumpAndSettle();
    expect((await BrowserBookmarkStore().load('npub-a')).map((b) => b.url),
        [second]);
    const editedUrl = 'https://second.example/short#today';
    send(0, 'editBookmark', {'url': second});
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Launch URL'),
        editedUrl);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
        (await BrowserBookmarkStore().load('npub-a')).single.startup, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    installFakeWebViewPlatform();
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    // Existing working windows take precedence over edited startup stars.
    expect(fakeLoadedRequestUrls, [first]);
  });

  testWidgets(
      'identity switch launches its choices and returns to running navigation state',
      (tester) async {
    await seed(stars: 1);
    final key = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    const navigation = 'https://first.example/working#today';
    submitFakeUrlChange(controllerIndex: 0, url: navigation);
    await tester.pumpAndSettle();
    await tester.pumpWidget(browser('npub-b', key: key));
    await tester.pumpAndSettle();
    expect(find.text('New Tab'), findsOneWidget);
    expect(fakeLoadedRequestUrls, [first]);
    expect(fakeLoadedHtmlStrings.last, isNot(contains('Open First')));
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [first, navigation]);
    expect(fakeLoadedRequestUrls.where((url) => url == builtIn), isEmpty);
  });

  testWidgets('delayed A to B to A reads cannot apply old stars or colours',
      (tester) async {
    final preferences = _DelayedPreferences();
    SharedPreferencesAsyncPlatform.instance = preferences;
    await seed(stars: 1, builtInStar: true);
    await BrowserBookmarkStore().saveLabelColour('npub-a', '#ffcc88');
    preferences.delay = true;
    final key = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    expect(preferences.reads, hasLength(1));
    expect(fakeLoadedRequestUrls, isEmpty);
    await tester.pumpWidget(browser('npub-b', key: key));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    await seed();
    await BrowserBookmarkStore().saveLabelColour('npub-a', '#ffffff');
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    expect(preferences.reads, hasLength(2));
    preferences.reads.first.complete();
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    preferences.reads.last.complete();
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(fakeLoadedHtmlStrings.last,
        isNot(contains('Open Flight Deck on startup')));
    expect(fakeLoadedHtmlStrings.last, contains('color:#ffffff;text-shadow'));
  });
  testWidgets('cold app requires PIN before restoring windows', (tester) async {
    await snapshot('npub-a', [
      {'is_home': false, 'url': second}
    ]);
    final vault = _RecoveryVault();
    await tester.pumpWidget(WingmanApp(signerVault: vault));
    await tester.pumpAndSettle();
    expect(find.byType(ImmediatePinField), findsOneWidget);
    expect(find.byType(BrowserScreen), findsNothing);
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(vault.unlocks, 0);
    await enterEditorText(tester, find.byType(ImmediatePinField), '0000');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect PIN.'), findsOneWidget);
    expect(fakeLoadedRequestUrls, isEmpty);
    await enterEditorText(tester, find.byType(ImmediatePinField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserScreen), findsOneWidget);
    expect(fakeLoadedRequestUrls, [second]);
    final raw = await SharedPreferencesAsync()
        .getString('wingman.browser.tabs.v3.npub-a');
    expect(raw, isNot(contains('fixture-secret')));
    expect(jsonDecode(raw!).keys.toSet(), {'version', 'active_index', 'tabs'});
  });

  testWidgets(
      'slow writes stay ordered and recreated screen waits for latest save',
      (tester) async {
    final preferences = _SlowTabsPreferences();
    SharedPreferencesAsyncPlatform.instance = preferences;
    final key = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    preferences.writeGate = Completer<void>();
    key.currentState!.openTab(first);
    await tester.pumpAndSettle();
    submitFakeUrlChange(controllerIndex: 1, url: second);
    await tester.pumpWidget(const SizedBox.shrink());
    installFakeWebViewPlatform();
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    preferences.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [second]);
    final saved = jsonDecode((await SharedPreferencesAsync()
        .getString('wingman.browser.tabs.v3.npub-a'))!);
    expect(saved['tabs'].last['url'], second);
  });

  testWidgets('late disk restore cannot cross identity boundary',
      (tester) async {
    final preferences = _SlowTabsPreferences();
    SharedPreferencesAsyncPlatform.instance = preferences;
    await snapshot('npub-a', [
      {'is_home': false, 'url': first}
    ]);
    await snapshot('npub-b', [
      {'is_home': false, 'url': second}
    ]);
    preferences.readGate = Completer<void>();
    final key = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(browser('npub-a', key: key));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    await tester.pumpWidget(browser('npub-b', key: key));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [second]);
    preferences.readGate!.complete();
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [second]);
  });
  testWidgets(
      'retired packaged app snapshot becomes home without loopback request',
      (tester) async {
    await snapshot('npub-a', [
      {'is_home': false, 'url': builtIn}
    ]);
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(find.text('New Tab'), findsOneWidget);
  });
}
