import 'dart:async';
import 'dart:convert';
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

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
  });
  Widget browser(String identity, {GlobalKey<BrowserScreenState>? key}) =>
      MaterialApp(
          home: Scaffold(
              body: BrowserScreen(
                  key: key,
                  config: AppConfig.defaults().copyWith(deviceNpub: identity),
                  localFlightDeckUrl: builtIn,
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
      'built-in star persists, renders, opens once and cannot be deleted',
      (tester) async {
    await seed(builtInStar: true);
    await tester.pumpWidget(browser('npub-a'));
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [builtIn]);
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    expect(
        fakeLoadedHtmlStrings.last,
        contains(
            'aria-label="Open Flight Deck on startup" aria-pressed="true"'));
    final controller = fakeWebViewControllerCreationCount - 1;
    send(controller, 'removeBookmark', {'url': builtIn});
    await tester.pumpAndSettle();
    expect(await BrowserBookmarkStore().loadBuiltInStartup('npub-a'), isTrue);
    expect(fakeLoadedHtmlStrings.last, contains('Flight Deck'));
    expect(fakeLoadedRequestUrls, [builtIn]);
  });

  testWidgets(
      'multiple stars including built-in deduplicate and persist across relaunch',
      (tester) async {
    await seed(stars: 2, builtInStar: true);
    final store = BrowserBookmarkStore();
    await store.save('npub-a', [
      ...await store.load('npub-a'),
      const BrowserBookmark(
          title: 'Old built-in bookmark', url: builtIn, startup: true)
    ]);
    for (var launch = 0; launch < 2; launch++) {
      installFakeWebViewPlatform();
      await tester.pumpWidget(browser('npub-a'));
      await tester.pumpAndSettle();
      expect(fakeLoadedRequestUrls, [builtIn, first, second]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
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
    expect(fakeLoadedRequestUrls, [editedUrl]);
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
    expect(
        fakeLoadedHtmlStrings.last,
        contains(
            'aria-label="Open Flight Deck on startup" aria-pressed="false"'));
    expect(fakeLoadedHtmlStrings.last, contains('color:#ffffff;text-shadow'));
  });
}
