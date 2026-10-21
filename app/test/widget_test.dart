import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wingman_app/src/app.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/flight_deck_update_models.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_relay_client.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/signer_vault.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'package:wingman_app/src/features/shell/shell_home.dart';
import 'package:wingman_app/src/features/shell/macos_menu_bridge.dart';

import 'fake_webview_platform.dart';
import 'package:wingman_app/src/features/browser/embedded_content_focus.dart';

class _AcceptProfileRelays extends NostrProfileRelayClient {
  @override
  Future<NostrProfileRelayResult?> fetchProfile(String publicKeyHex) async =>
      null;
  @override
  Future<ProfilePublishResult> publish(Map<String, dynamic> event) async =>
      const ProfilePublishResult(
          acceptedRelays: ['wss://test.invalid'], totalRelays: 1);
}

void main() {
  int activeBrowserStackIndex(WidgetTester tester) {
    return tester
            .widgetList<IndexedStack>(find.byType(IndexedStack))
            .last
            .index ??
        0;
  }

  Rect browserContentViewportRect(WidgetTester tester) {
    return tester.getRect(
      find.byKey(const ValueKey('browser-content-viewport')),
    );
  }

  Future<void> openNewBrowserTab(WidgetTester tester) async {
    final mobileCount = find.byKey(const ValueKey('browser-mobile-tab-count'));
    if (mobileCount.evaluate().isNotEmpty) {
      await tester.tap(mobileCount);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
  }

  Future<void> tapBrowserTab(WidgetTester tester, int id) async {
    final desktopTab = find.byKey(ValueKey('tab-$id'));
    if (desktopTab.evaluate().isNotEmpty) {
      await tester.ensureVisible(desktopTab);
      await tester.pumpAndSettle();
      await tester.tap(desktopTab);
      await tester.pumpAndSettle();
      return;
    }
    await tester.tap(find.byKey(const ValueKey('browser-mobile-tab-count')));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('tab-overview-$id'));
    final shape = tester
        .widget<Material>(
          find.descendant(of: card, matching: find.byType(Material)).first,
        )
        .shape! as RoundedRectangleBorder;
    if (shape.side.width == 3) {
      await tester.tap(find.byTooltip('Close tab overview'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('browser-mobile-current-tab')),
      );
    } else {
      await tester.tap(card);
    }
    await tester.pumpAndSettle();
  }

  Future<void> closeBrowserTab(WidgetTester tester, int id) async {
    final desktopTab = find.byKey(ValueKey('tab-$id'));
    if (desktopTab.evaluate().isNotEmpty) {
      await tester.tap(find.descendant(
        of: desktopTab,
        matching: find.byTooltip('Close tab'),
      ));
      await tester.pumpAndSettle();
      return;
    }
    await tester.tap(find.byKey(const ValueKey('browser-mobile-tab-count')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byKey(ValueKey('tab-overview-$id')),
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close tab overview'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
  });

  test('default configuration has no packaged service destinations', () {
    final config = AppConfig.defaults();

    expect(config.towerUrl, isEmpty);
    expect(config.flightDeckUrl, isEmpty);
    expect(config.appNpub, isEmpty);
    expect(config.workspaceId, isEmpty);
    expect(config.workspaceServiceNpub, isEmpty);
    expect(config.channelId, isEmpty);
    expect(config.trustedOrigins, isEmpty);
    expect(config.displayExperimentalFlightDeckDriveSync, isFalse);
  });

  testWidgets('Android sends touch gestures directly to embedded web views',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowserScreen(
              config: AppConfig.defaults(),
              bridge: NativeCoreBridge(),
              signerStore: SignerStore(),
              onOpenDrawer: () {},
              onOpenSetup: () {},
              onOpenSigner: () {},
              onOpenStatus: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
          find.ancestor(
              of: find.byType(WebViewWidget),
              matching: find.byType(EmbeddedContentFocus)),
          findsOneWidget);
      final webView = tester.widget<WebViewWidget>(find.byType(WebViewWidget));
      expect(webView.gestureRecognizers, hasLength(1));
      expect(
        webView.gestureRecognizers.single.constructor(),
        isA<EagerGestureRecognizer>(),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'address controls overlay the unchanged web viewport at narrow and wide sizes',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final size in <Size>[
      const Size(360, 640),
      const Size(1280, 800),
    ]) {
      tester.view.physicalSize = size;
      installFakeWebViewPlatform();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowserScreen(
              config: AppConfig.defaults(),
              bridge: NativeCoreBridge(),
              signerStore: SignerStore(),
              onOpenDrawer: () {},
              onOpenSetup: () {},
              onOpenSigner: () {},
              onOpenStatus: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final hiddenViewport = browserContentViewportRect(tester);
      expect(find.byTooltip('Back'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byTooltip('Back'), findsNothing);

      await tapBrowserTab(tester, 1);

      expect(browserContentViewportRect(tester), hiddenViewport);
      expect(find.byTooltip('Back'), findsOneWidget);
      final overlay = tester.getRect(
        find.byKey(const ValueKey('browser-address-bar-overlay')),
      );
      expect(overlay.top, hiddenViewport.top);
      expect(overlay.left, hiddenViewport.left);
      expect(overlay.right, hiddenViewport.right);
      expect(overlay.bottom, lessThan(hiddenViewport.bottom));

      final targetUrl = 'https://${size.width.toInt()}.example';
      await tester.enterText(find.byType(TextField), targetUrl);
      await tester.tap(find.byTooltip('Go'));
      await tester.pump();

      expect(fakeLoadedRequestUrls, contains(targetUrl));
      expect(browserContentViewportRect(tester), hiddenViewport);

      await tester.pump(const Duration(seconds: 6));
      expect(find.byTooltip('Back'), findsNothing);
      expect(browserContentViewportRect(tester), hiddenViewport);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
      'active tab collapses address bar without navigation and cancels its timer',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New tab'));
    await tester.pump();

    final controllerCount = fakeWebViewControllerCreationCount;
    final requestCount = fakeLoadedRequestUrls.length;
    final htmlLoadCount = fakeLoadedHtmlStrings.length;
    expect(find.byTooltip('Back'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    expect(find.byTooltip('Back'), findsNothing);
    expect(fakeWebViewControllerCreationCount, controllerCount);
    expect(fakeLoadedRequestUrls, hasLength(requestCount));
    expect(fakeLoadedHtmlStrings, hasLength(htmlLoadCount));

    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    expect(find.byTooltip('Back'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    expect(find.byTooltip('Back'), findsOneWidget);

    // The cancelled reveal timer from tab 2 would fire here if stale.
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.byTooltip('Back'), findsNothing);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.iOS,
    TargetPlatform.android
  ]) {
    testWidgets('$platform address bar requires an active-tab tap',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = platform == TargetPlatform.macOS
            ? const Size(1280, 800)
            : const Size(390, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final browserKey = GlobalKey<BrowserScreenState>();
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: BrowserScreen(
          key: browserKey,
          config: AppConfig.defaults(),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onOpenDrawer: () {},
          onOpenSetup: () {},
          onOpenSigner: () {},
          onOpenStatus: () {},
        ))));
        final bar = find.byKey(const ValueKey('browser-address-bar-overlay'));
        Future<void> tapTab(int id) => tapBrowserTab(tester, id);

        await tester.pumpAndSettle();
        expect(bar, findsNothing);
        await openNewBrowserTab(tester);
        expect(bar, findsNothing);
        await tapTab(1); // Switching while hidden stays hidden.
        expect(activeBrowserStackIndex(tester), 0);
        expect(bar, findsNothing);
        await tapTab(1);
        expect(bar, findsOneWidget);
        await tapTab(2); // Switching while visible dismisses immediately.
        expect(activeBrowserStackIndex(tester), 1);
        expect(bar, findsNothing);
        await tapTab(2);
        await tester.enterText(find.byType(TextField), 'https://draft.example');
        await tester.pump(const Duration(seconds: 6));
        expect(bar, findsOneWidget); // Editing outlives the reveal timer.
        await tapTab(1);
        expect(bar, findsNothing);
        await tapTab(2);
        expect(
            bar, findsNothing); // Old editing focus must not reveal it again.
        await tapTab(2);
        expect(
            tester.widget<TextField>(find.byType(TextField)).controller?.text,
            'https://draft.example');
        browserKey.currentState!.openTab('https://opened.example');
        await tester.pumpAndSettle();
        expect(bar, findsNothing);
        await tapTab(3);
        expect(bar, findsOneWidget);
        await closeBrowserTab(tester, 3);
        expect(bar, findsNothing);
        await tapTab(2);
        expect(bar, findsOneWidget);
        await openNewBrowserTab(tester);
        expect(bar, findsNothing);
        await tester.pump(const Duration(seconds: 6));
        expect(bar, findsNothing);
        // Closing a background tab must not reveal the active tab's address.
        if (platform == TargetPlatform.macOS) {
          final backgroundClose = find.descendant(
              of: find.byKey(const ValueKey('tab-1')),
              matching: find.byTooltip('Close tab'));
          await tester.ensureVisible(backgroundClose);
          await tester.pumpAndSettle();
          await tester.tap(backgroundClose);
          await tester.pumpAndSettle();
          expect(bar, findsNothing);
        }
        // Closing the last tab creates a replacement with its address hidden.
        for (final id in [4, 2, if (platform != TargetPlatform.macOS) 1]) {
          await tapTab(id);
          expect(bar, findsOneWidget);
          await closeBrowserTab(tester, id);
          expect(bar, findsNothing);
        }
        expect(find.text('New Tab'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('address bar tracks the complete current webview URL',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();
    const initialUrl = 'https://service-3.example.com/';
    await tester.enterText(find.byType(TextField), initialUrl);
    await tester.tap(find.byTooltip('Go'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pump();

    const navigatedUrl =
        'https://service-3.example.com/live/example-session?view=full#activity';
    submitFakeUrlChange(controllerIndex: 0, url: navigatedUrl);
    await tester.pump();

    final addressField = tester.widget<TextField>(find.byType(TextField));
    expect(addressField.controller?.text, navigatedUrl);
    expect(fakeLoadedRequestUrls, <String>[initialUrl]);
    expect(fakeWebViewControllerCreationCount, 1);
  });

  testWidgets('FIPS tabs show the mesh transport indicator', (tester) async {
    final browserKey = GlobalKey<BrowserScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            key: browserKey,
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final npub = 'npub1${List.filled(58, 'q').join()}';

    browserKey.currentState!.openTab('http://$npub.fips:41024/');
    await tester.pump();

    expect(
      find.byKey(const ValueKey('fips-transport-indicator')),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Encrypted FIPS mesh transport'),
      findsOneWidget,
    );
  });

  testWidgets('FIPS navigation waits for bundled runtime readiness',
      (tester) async {
    final browserKey = GlobalKey<BrowserScreenState>();
    final readiness = Completer<String?>();
    final preparedUrls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            key: browserKey,
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
            onPrepareFipsNavigation: (url) {
              preparedUrls.add(url);
              return readiness.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final npub = 'npub1${List.filled(58, 'q').join()}';
    final url = 'http://$npub.fips:41024/';

    browserKey.currentState!.openTab(url);
    await tester.pump();

    expect(preparedUrls, [url]);
    expect(fakeLoadedRequestUrls, isEmpty);

    readiness.complete(null);
    await tester.pump();

    expect(fakeLoadedRequestUrls, [url]);
  });

  testWidgets('clean launch renders a neutral browser signer new tab',
      (tester) async {
    await tester.pumpWidget(
      const WingmanApp(useSignerVault: false),
    );
    await tester.pump();

    expect(find.byTooltip('New tab'), findsOneWidget);
    expect(find.byTooltip('Profile'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.text('New Tab'), findsOneWidget);
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(fakeLoadedHtmlStrings.last, contains('Saved apps'));
    expect(fakeLoadedHtmlStrings.last, isNot(contains('Flight Deck')));
    expect(fakeLoadedHtmlStrings.last, isNot(contains('Tower')));
    expect(fakeLoadedHtmlStrings.last, isNot(contains('Autopilot')));
    expect(fakeLoadedHtmlStrings.last, isNot(contains('runwingman.com')));
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    expect(find.byTooltip('Back'), findsNothing);

    await tester.tap(find.text('New Tab'));
    await tester.pump();
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.byTooltip('Back'), findsNothing);

    await tester.tap(find.byTooltip('New tab'));
    await tester.pump();
    expect(find.text('New Tab'), findsNWidgets(2));
    expect(fakeLoadedHtmlStrings.last, isNot(contains('data-wingman-tab-url')));

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Signer').last);
    await tester.pumpAndSettle();
    expect(find.text('Signer'), findsAtLeastNWidgets(1));

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browser').last);
    await tester.pumpAndSettle();
    expect(find.text('New Tab'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();

    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Drive'), findsOneWidget);
    expect(find.text('Signer'), findsAtLeastNWidgets(1));
    expect(find.text('Status'), findsAtLeastNWidgets(1));

    await tester.tapAt(const Offset(500, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Setup'), findsOneWidget);
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    final resetBrowserDataButton =
        find.widgetWithText(OutlinedButton, 'Reset browser data');
    expect(resetBrowserDataButton, findsOneWidget);

    await tester.tap(resetBrowserDataButton);
    await tester.pumpAndSettle();
    expect(find.text('Reset browser data?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(fakeClearCookieCalls, 1);
  });

  testWidgets(
      'packaged Flight Deck uses live titles, fallbacks, and SPA updates',
      (tester) async {
    const flightDeckUrl = 'http://127.0.0.1:47831/';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            config: AppConfig.defaults(),
            localFlightDeckUrl: flightDeckUrl,
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    submitFakeJavaScriptMessage(
        controllerIndex: 0,
        channel: 'WingmanSigner',
        message:
            '{"id":"open-built-in","method":"navigateTab","params":{"url":"$flightDeckUrl"}}');
    await tester.pumpAndSettle();

    expect(fakeLoadedRequestUrls.single, flightDeckUrl);
    expect(find.text('Flight Deck'), findsOneWidget);

    setFakePageTitle(
      controllerIndex: 0,
      title: '  Tasks · Owner Workspace  ',
    );
    submitFakePageFinished(controllerIndex: 0, url: flightDeckUrl);
    await tester.pumpAndSettle();

    expect(find.text('Tasks · Owner Workspace'), findsOneWidget);
    expect(
      fakeExecutedJavaScripts,
      contains(predicate<String>((script) =>
          script.contains('MutationObserver') &&
          script.contains('WingmanTitle.postMessage'))),
    );

    submitFakeJavaScriptMessage(
      controllerIndex: 0,
      channel: 'WingmanTitle',
      message: '  Sessions · Wingman  ',
    );
    await tester.pump();
    expect(find.text('Sessions · Wingman'), findsOneWidget);

    submitFakeJavaScriptMessage(
      controllerIndex: 0,
      channel: 'WingmanTitle',
      message: '   ',
    );
    await tester.pump();
    expect(find.text('Flight Deck'), findsOneWidget);

    setFakeTitleRetrievalFailure(controllerIndex: 0, fails: true);
    submitFakePageFinished(controllerIndex: 0, url: flightDeckUrl);
    await tester.pumpAndSettle();
    expect(find.text('Flight Deck'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Close tab'));
    await tester.pump();

    expect(find.text('New Tab'), findsOneWidget);
    expect(fakeLoadedHtmlStrings.last, contains('Flight Deck'));
    expect(fakeLoadedHtmlStrings.last, contains(flightDeckUrl));
    expect(
      fakeLoadedHtmlStrings.last,
      isNot(contains('Remove Flight Deck bookmark')),
    );

    submitFakeJavaScriptMessage(
      controllerIndex: 1,
      channel: 'WingmanSigner',
      message:
          '{"id":"flight-deck-open","method":"navigateTab","params":{"url":"$flightDeckUrl"}}',
    );
    await tester.pump();

    setFakePageTitle(controllerIndex: 1, title: 'Overview · Owner Workspace');
    submitFakePageFinished(controllerIndex: 1, url: flightDeckUrl);
    await tester.pumpAndSettle();

    expect(fakeLoadedRequestUrls.last, flightDeckUrl);
    expect(find.text('Overview · Owner Workspace'), findsOneWidget);
  });

  testWidgets('tab colours and prefixes survive title changes and restore',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      const storageKey = 'wingman.browser.tabs.v3.npub-tab-appearance';
      Widget browser() => MaterialApp(
              home: Scaffold(
                  body: BrowserScreen(
            config: AppConfig.defaults()
                .copyWith(deviceNpub: 'npub-tab-appearance'),
            localFlightDeckUrl: 'http://127.0.0.1:47831/',
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          )));
      Future<void> menu() async {
        await tester.tap(find.byKey(const ValueKey('tab-1')),
            buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        expect(find.text('Set tab prefix…'), findsOneWidget);
      }

      Future<void> editPrefix(String value, {bool cancel = false}) async {
        await menu();
        await tester.tap(find.text('Set tab prefix…'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), value);
        await tester.tap(find.text(cancel ? 'Cancel' : 'Save'));
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(browser());
      await tester.pumpAndSettle();
      submitFakeJavaScriptMessage(
          controllerIndex: 0,
          channel: 'WingmanSigner',
          message:
              '{"id":"open-built-in","method":"navigateTab","params":{"url":"http://127.0.0.1:47831/"}}');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();
      await menu();
      await tester
          .tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Blue'));
      await tester.pumpAndSettle();
      expect(activeBrowserStackIndex(tester), 1);
      await editPrefix(' WORK:  ');
      expect(find.text('WORK: Flight Deck'), findsOneWidget);
      setFakePageTitle(controllerIndex: 0, title: 'Tasks');
      submitFakePageFinished(
          controllerIndex: 0, url: 'http://127.0.0.1:47831/');
      await tester.pumpAndSettle();
      expect(find.text('WORK: Tasks'), findsOneWidget);
      final saved =
          jsonDecode((await SharedPreferencesAsync().getString(storageKey))!)
              as Map;
      expect(saved['tabs'][0]['prefix'], 'WORK');
      expect(saved['tabs'][0]['colour'], 'Blue');
      expect(saved['tabs'][0]['title'], 'Tasks');
      expect(saved['tabs'][1].containsKey('prefix'), isFalse);
      await menu();
      expect(
          tester
              .widget<CheckedPopupMenuItem<String>>(
                  find.widgetWithText(CheckedPopupMenuItem<String>, 'Blue'))
              .checked,
          isTrue);
      await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'Default colour'));
      await tester.pumpAndSettle();
      await editPrefix('Discarded', cancel: true);
      expect(find.text('WORK: Tasks'), findsOneWidget);
      await editPrefix('');
      expect(find.text('Tasks'), findsOneWidget);
      final cleared =
          jsonDecode((await SharedPreferencesAsync().getString(storageKey))!)
              as Map;
      expect(cleared['tabs'][0].containsKey('prefix'), isFalse);
      expect(cleared['tabs'][0].containsKey('colour'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      installFakeWebViewPlatform();
      await tester.pumpWidget(browser());
      await tester.pumpAndSettle();
      expect(find.text('New Tab'), findsOneWidget);
      expect(find.text('WORK: Flight Deck'), findsNothing);
      expect(fakeLoadedRequestUrls, isEmpty);
      final retained =
          jsonDecode((await SharedPreferencesAsync().getString(storageKey))!)
              as Map;
      // Startup doesn't restore the tab prefix; the saved record remains readable.
      expect(retained['tabs'], isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('restored generic web labels are replaced by the live title',
      (tester) async {
    const signer = 'npub-restored-live-title';
    const flightDeckUrl = 'http://127.0.0.1:47831/';
    final preferences = SharedPreferencesAsync();
    await preferences.setString('wingman.browser.last_signer_npub.v1', signer);
    await preferences.setString(
      'wingman.browser.tabs.v1.$signer',
      '{"version":2,"active_index":0,"tabs":['
          '{"title":"Flight Deck","url":"$flightDeckUrl","is_home":false}'
          ']}',
    );

    await BrowserBookmarkStore().saveBuiltInStartup(signer, true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            config: AppConfig.defaults().copyWith(deviceNpub: signer),
            localFlightDeckUrl: flightDeckUrl,
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final restoredController = fakeWebViewControllerCreationCount - 1;
    setFakePageTitle(
      controllerIndex: restoredController,
      title: 'Board · Restored Workspace',
    );
    submitFakePageFinished(
      controllerIndex: restoredController,
      url: flightDeckUrl,
    );
    await tester.pumpAndSettle();

    expect(find.text('Board · Restored Workspace'), findsOneWidget);
    expect(find.text('Flight Deck'), findsNothing);
  });

  testWidgets('legacy snapshots never seed packaged Flight Deck',
      (tester) async {
    const signer = 'npub-flight-deck-upgrade';
    const flightDeckUrl = 'http://127.0.0.1:47831/';
    const tabsKey = 'wingman.browser.tabs.v1.$signer';
    final preferences = SharedPreferencesAsync();
    await preferences.setString(
      tabsKey,
      '{"version":1,"active_index":0,"tabs":[{"title":"New Tab","url":null,"is_home":true}]}',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserScreen(
            config: AppConfig.defaults().copyWith(deviceNpub: signer),
            localFlightDeckUrl: flightDeckUrl,
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onOpenDrawer: () {},
            onOpenSetup: () {},
            onOpenSigner: () {},
            onOpenStatus: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Flight Deck'), findsNothing);
    expect(find.text('New Tab'), findsOneWidget);
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(await preferences.getString(tabsKey),
        '{"version":1,"active_index":0,"tabs":[{"title":"New Tab","url":null,"is_home":true}]}');
  });

  testWidgets('desktop-width strip scrolls and reorders ordinary tabs',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowserScreen(
              config: AppConfig.defaults(),
              bridge: NativeCoreBridge(),
              signerStore: SignerStore(),
              onOpenDrawer: () {},
              onOpenSetup: () {},
              onOpenSigner: () {},
              onOpenStatus: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      const firstTabKey = ValueKey('tab-1');
      expect(activeBrowserStackIndex(tester), 0);
      expect(find.byKey(firstTabKey), findsOneWidget);
      await tester.tap(find.byTooltip('New tab'));
      await tester.pump();

      for (final entry in <(String, String)>[
        ('docs', 'https://docs.example'),
        ('files', 'https://files.example'),
        ('autopilot', 'https://service-3.example.com'),
      ]) {
        submitFakeJavaScriptMessage(
          controllerIndex: 1,
          channel: 'WingmanSigner',
          message:
              '{"id":"${entry.$1}","method":"openTab","params":{"url":"${entry.$2}"}}',
        );
        await tester.pumpAndSettle();
      }

      final strip = find.byKey(const ValueKey('browser-tab-strip'));
      final autopilot = find.byKey(const ValueKey('tab-5'));
      final stripRect = tester.getRect(strip);

      await tester.dragUntilVisible(
        autopilot,
        strip,
        const Offset(-100, 0),
      );
      await tester.drag(strip, const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(firstTabKey), findsNothing);
      final autopilotRect = tester.getRect(autopilot);
      expect(autopilotRect.left, greaterThanOrEqualTo(stripRect.left));
      expect(autopilotRect.right, lessThanOrEqualTo(stripRect.right));
      expect(autopilotRect.width, greaterThanOrEqualTo(96));

      await tester.tap(find.text('service-3.example.com'));
      await tester.pump();
      expect(activeBrowserStackIndex(tester), 4);

      tester.widget<ReorderableListView>(strip).onReorderItem!.call(4, 3);
      await tester.pumpAndSettle();
      expect(activeBrowserStackIndex(tester), 3);

      expect(find.byKey(const ValueKey('browser-mobile-tab-header')),
          findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Wingman shell clears browser web state when signer changes',
      (tester) async {
    const profileKey = 'wingman.browser.last_signer_npub.v1';
    final preferences = SharedPreferencesAsync();
    await preferences.setString(profileKey, 'npub-old');

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            deviceSecret: 'nsec-placeholder',
            deviceNpub: 'npub-new',
            devicePublicKeyHex: 'abcdef',
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(fakeClearCookieCalls, 1);
    expect(await preferences.getString(profileKey), 'npub-new');
  });

  testWidgets('Wingman shell reloads local Flight Deck after automatic update',
      (tester) async {
    const flightDeckUrl = 'http://127.0.0.1:47831/';
    final updates = _ShellFlightDeckUpdateController(
      _flightDeckSnapshot(
        phase: FlightDeckUpdatePhase.idle,
        active: 'Build 100 (packaged)',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults(),
          localFlightDeckUrl: flightDeckUrl,
          flightDeckUpdates: updates,
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    submitFakeJavaScriptMessage(
        controllerIndex: 0,
        channel: 'WingmanSigner',
        message:
            '{"id":"open-built-in","method":"navigateTab","params":{"url":"$flightDeckUrl"}}');
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, [flightDeckUrl]);
    expect(fakeReloadCalls, 0);

    updates.activate('Build 101 (ota-test)');
    await tester.pump();
    await tester.pump();

    expect(fakeReloadCalls, 1);

    updates.republish();
    await tester.pump();
    await tester.pump();

    expect(fakeReloadCalls, 1);
  });

  testWidgets(
      'Wingman shell uses startup selection on relaunch instead of disk tabs',
      (tester) async {
    final config = AppConfig.defaults().copyWith(
      deviceSecret: 'nsec-placeholder',
      deviceNpub: 'npub-tabs',
      devicePublicKeyHex: 'abcdef',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: config,
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New tab'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'https://service-3.example.com',
    );
    await tester.tap(find.byTooltip('Go'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byTooltip('New tab'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('New Tab'), findsNWidgets(2));
    expect(find.text('service-3.example.com'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    installFakeWebViewPlatform();

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: config,
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New Tab'), findsOneWidget);
    expect(find.text('service-3.example.com'), findsNothing);
    expect(fakeLoadedRequestUrls, isEmpty);
    expect(find.byTooltip('Back'), findsNothing);
  });

  testWidgets('legacy pinned snapshots cannot override zero startup stars',
      (tester) async {
    const signer = 'npub-legacy-tabs';
    final preferences = SharedPreferencesAsync();
    await preferences.setString('wingman.browser.last_signer_npub.v1', signer);
    await preferences.setString(
      'wingman.browser.tabs.v1.$signer',
      '{"version":1,"active_index":1,"tabs":['
          '{"title":"Flight Deck","url":"https://user-flightdeck.example","is_home":false,"pinned":true},'
          '{"title":"My site","url":"https://user-site.example","is_home":false,"pinned":false}'
          ']}',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            deviceSecret: 'nsec-placeholder',
            deviceNpub: signer,
            devicePublicKeyHex: 'abcdef',
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(fakeLoadedRequestUrls, isEmpty);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    expect(find.byTooltip('Close tab'), findsOneWidget);
    expect(await preferences.getString('wingman.browser.tabs.v1.$signer'),
        contains('https://user-flightdeck.example'));
  });

  testWidgets('browser saved apps edit actual URL, reload, open, and remove',
      (tester) async {
    final config = AppConfig.defaults().copyWith(
      deviceSecret: 'nsec-placeholder',
      deviceNpub: 'npub-bookmarks',
      devicePublicKeyHex: 'abcdef',
    );

    Widget shell() => MaterialApp(
          home: ShellHome(
            config: config,
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onConfigChanged: (_) {},
          ),
        );

    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New tab'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'HTTPS://Example.COM/projects/one?view=board#today',
    );
    await tester.tap(find.byTooltip('Go'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('Add bookmark'), findsOneWidget);
    expect(
        find.bySemanticsLabel('Add bookmark for current page'), findsOneWidget);
    await tester.tap(find.text('Add bookmark'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('Remove bookmark'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove bookmark for current page'),
        findsOneWidget);
    await tester.tapAt(const Offset(500, 300));
    await tester.pumpAndSettle();

    await openNewBrowserTab(tester);
    const canonicalUrl = 'https://example.com/projects/one?view=board#today';
    expect(fakeLoadedHtmlStrings.last, contains('example.com'));
    expect(fakeLoadedHtmlStrings.last, contains(canonicalUrl));
    expect(fakeLoadedHtmlStrings.last, contains('class="app-open"'));
    expect(fakeLoadedHtmlStrings.last, contains('Edit apps and background'));
    final homeControllerIndex = fakeWebViewControllerCreationCount - 1;
    submitFakeJavaScriptMessage(
        controllerIndex: homeControllerIndex,
        channel: 'WingmanSigner',
        message: jsonEncode({
          'id': 'star-before-edit',
          'method': 'setStartup',
          'params': {'url': canonicalUrl, 'enabled': true}
        }));
    await tester.pumpAndSettle();
    submitFakeJavaScriptMessage(
        controllerIndex: homeControllerIndex,
        channel: 'WingmanSigner',
        message: jsonEncode({
          'id': 'edit',
          'method': 'editBookmark',
          'params': {'url': canonicalUrl}
        }));
    await tester.pumpAndSettle();
    expect(find.text('Edit saved app'), findsOneWidget);
    final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'App name');
    final urlField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Launch URL');
    await tester.enterText(nameField, 'Project board');
    const editedUrl = 'https://example.com/projects?intentional=1#part';
    await tester.enterText(urlField, editedUrl);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fakeLoadedHtmlStrings.last, contains('Project board'));
    expect(fakeLoadedHtmlStrings.last, contains(editedUrl));
    expect(fakeLoadedHtmlStrings.last, isNot(contains(canonicalUrl)));
    final savedApp =
        (await BrowserBookmarkStore().load(config.deviceNpub)).single;
    expect(savedApp.startup, isTrue);
    expect(savedApp.url, editedUrl);
    // Unstar before the existing launcher interaction checks below.
    submitFakeJavaScriptMessage(
        controllerIndex: homeControllerIndex,
        channel: 'WingmanSigner',
        message: jsonEncode({
          'id': 'unstar-after-edit',
          'method': 'setStartup',
          'params': {'url': editedUrl, 'enabled': false}
        }));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    installFakeWebViewPlatform();
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();

    expect(fakeLoadedHtmlStrings.last, contains(editedUrl));
    expect(fakeLoadedHtmlStrings.last, contains('Project board'));
    final controllerCount = fakeWebViewControllerCreationCount;
    submitFakeJavaScriptMessage(
      controllerIndex: controllerCount - 1,
      channel: 'WingmanSigner',
      message:
          '{"id":"bookmark-open","method":"navigateTab","params":{"url":"$editedUrl"}}',
    );
    await tester.pumpAndSettle();
    expect(fakeWebViewControllerCreationCount, controllerCount);
    expect(fakeLoadedRequestUrls.last, editedUrl);

    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    final removalHomeControllerIndex = fakeWebViewControllerCreationCount - 1;
    submitFakeJavaScriptMessage(
      controllerIndex: removalHomeControllerIndex,
      channel: 'WingmanSigner',
      message:
          '{"id":"bookmark-remove","method":"removeBookmark","params":{"url":"$editedUrl"}}',
    );
    await tester.pumpAndSettle();
    expect(fakeLoadedHtmlStrings.last, contains('No saved apps yet'));
    expect(fakeLoadedHtmlStrings.last, isNot(contains(editedUrl)));
  });

  testWidgets('new-tab bookmark layout wraps long labels at narrow width',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    final preferences = SharedPreferencesAsync();
    const signer = 'npub-long-bookmark';
    final longTitle = List.filled(40, 'VeryLongTitle').join();
    await preferences.setString(
      'wingman.browser.bookmarks.v1.$signer',
      '{"version":1,"bookmarks":[{"title":"$longTitle","url":"https://example.com/a/very/long/path?with=query"}]}',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            deviceSecret: 'nsec-placeholder',
            deviceNpub: signer,
            devicePublicKeyHex: 'abcdef',
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openNewBrowserTab(tester);

    expect(tester.takeException(), isNull);
    expect(fakeLoadedHtmlStrings.last, contains(longTitle));
    expect(fakeLoadedHtmlStrings.last, contains('overflow-wrap:anywhere'));
    expect(fakeLoadedHtmlStrings.last, contains('min-width:0'));
  });

  testWidgets('Wingman browser cycles tabs with Ctrl+Tab', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            deviceSecret: 'nsec-placeholder',
            deviceNpub: 'npub-keyboard-tabs',
            devicePublicKeyHex: 'abcdef',
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(activeBrowserStackIndex(tester), 0);

    await tester.tap(find.byTooltip('New tab'));
    await tester.pump();
    expect(activeBrowserStackIndex(tester), 1);
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(activeBrowserStackIndex(tester), 0);
    expect(find.byTooltip('Back'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(activeBrowserStackIndex(tester), 1);
  });

  testWidgets(
      'Artifact iframe navigation stays in its tab and explicit openTab creates one tab',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            deviceSecret: 'nsec-placeholder',
            deviceNpub: 'npub-artifact-iframe',
            devicePublicKeyHex: 'abcdef',
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New tab'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'https://artifact.example/control',
    );
    await tester.tap(find.byTooltip('Go'));
    await tester.pump();

    expect(find.byKey(const ValueKey('tab-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-3')), findsNothing);
    expect(activeBrowserStackIndex(tester), 1);

    for (final url in <String>[
      'about:blank',
      'https://artifact.example/artifact-frame/project/artifact/v1/index.html',
      'https://preview.example/rendered-artifact',
    ]) {
      final decision = await submitFakeNavigationRequest(
        controllerIndex: 1,
        url: url,
        isMainFrame: false,
      );
      await tester.pump();

      expect(decision, NavigationDecision.navigate, reason: url);
      expect(find.byKey(const ValueKey('tab-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tab-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('tab-3')), findsNothing);
      expect(fakeWebViewControllerCreationCount, 2);
      expect(activeBrowserStackIndex(tester), 1);
    }

    expect(
      fakeExecutedJavaScripts,
      contains(
        allOf(
          contains('window.open = (url, target, features)'),
          contains("target || '_blank'"),
          contains("normalizedTarget !== '_self'"),
          contains("anchor.getAttribute('target')"),
          contains("linkTarget === '_self'"),
          contains("method: 'openTab'"),
        ),
      ),
    );

    submitFakeJavaScriptMessage(
      controllerIndex: 1,
      channel: 'WingmanSigner',
      message: '''
{"id":"popup-1","method":"openTab","params":{"url":"https://popup.example/page"}}
''',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('tab-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-3')), findsOneWidget);
    expect(fakeWebViewControllerCreationCount, 3);
    expect(activeBrowserStackIndex(tester), 2);
    expect(fakeLoadedRequestUrls.last, 'https://popup.example/page');
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.macOS
  ]) {
    testWidgets('$platform focus edge navigation preserves tabs and drawer',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        tester.view.physicalSize = platform == TargetPlatform.macOS
            ? const Size(1280, 852)
            : const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
            home: ShellHome(
          config: AppConfig.defaults(),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        )));
        await tester.pumpAndSettle();
        final mobile = platform != TargetPlatform.macOS;
        Future<void> next() async {
          await tester.dragFrom(const Offset(390, 400), const Offset(-120, 0));
          await tester.pump();
        }

        // Normal mode has no shell swipe interception.
        await next();
        expect(activeBrowserStackIndex(tester), 0);
        await tester.tap(find.byTooltip('Enter Focus Mode'));
        await tester.pump();
        await next();
        expect(activeBrowserStackIndex(tester), 0); // one tab
        await tester.dragFrom(const Offset(180, 5), const Offset(0, 120));
        await tester.pump();
        expect(find.byTooltip('Enter Focus Mode'),
            mobile ? findsOneWidget : findsNothing);
        if (!mobile) {
          tester
              .state<BrowserScreenState>(find.byType(BrowserScreen))
              .exitFocusMode();
          await tester.pump();
        }
        await openNewBrowserTab(tester);
        await openNewBrowserTab(tester);
        if (!mobile) {
          // Desktop retains reordering: the selected last tab moves first.
          tester
              .widget<ReorderableListView>(find.byType(ReorderableListView))
              .onReorderItem!(2, 0);
          await tester.pumpAndSettle();
          expect(activeBrowserStackIndex(tester), 0);
        } else {
          expect(activeBrowserStackIndex(tester), 2);
        }
        final controllers = tester
            .widgetList<WebViewWidget>(
                find.byType(WebViewWidget, skipOffstage: false))
            .map((view) => view.platform.params.controller)
            .toList();
        final loads = [...fakeLoadedRequestUrls];
        final htmlLoads = [...fakeLoadedHtmlStrings];
        await tester.tap(find.byTooltip('Enter Focus Mode'));
        await tester.pump();
        final expectedIndexes = mobile ? [0, 1, 2, 0] : [0, 0, 0, 0];
        for (final index in expectedIndexes) {
          await next();
          expect(activeBrowserStackIndex(tester), index);
          expect(find.byTooltip('Enter Focus Mode'), findsNothing);
        }
        expect(
            tester
                .widgetList<WebViewWidget>(
                    find.byType(WebViewWidget, skipOffstage: false))
                .map((view) => view.platform.params.controller)
                .toList(),
            controllers);
        expect(fakeWebViewControllerCreationCount, 3);
        expect(fakeLoadedRequestUrls, loads);
        expect(fakeLoadedHtmlStrings, htmlLoads);
        expect(fakeReloadCalls, 0);
        if (mobile) {
          await tester.dragFrom(const Offset(0, 5), const Offset(280, 0));
          await tester.pumpAndSettle();
          expect(find.text('Show controls'), findsOneWidget);
          await tester.tap(find.text('Show controls'));
          await tester.pumpAndSettle();
          expect(activeBrowserStackIndex(tester), 0);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('Focus Mode preserves the active browser tab and restores chrome',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final config = AppConfig.defaults().copyWith(
      deviceSecret: 'nsec-placeholder',
      deviceNpub: 'npub-focus-mode',
      devicePublicKeyHex: 'abcdef',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: ThemeMode.dark,
        home: ShellHome(
          config: config,
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openNewBrowserTab(tester);
    expect(activeBrowserStackIndex(tester), 1);
    expect(find.text('New Tab'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('browser-mobile-tab-count')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    final controllerCountBeforeFocus = fakeWebViewControllerCreationCount;

    await tester.tap(find.byTooltip('Enter Focus Mode'));
    await tester.pump();

    expect(activeBrowserStackIndex(tester), 1);
    expect(find.byTooltip('Exit Focus Mode'), findsNothing);
    expect(find.byTooltip('Enter Focus Mode'), findsNothing);
    expect(find.byTooltip('Open menu'), findsNothing);
    expect(find.byTooltip('New tab'), findsNothing);
    expect(find.byTooltip('Profile'), findsNothing);
    expect(find.bySemanticsLabel('Exit Focus Mode'), findsNothing);
    expect(find.text('New Tab'), findsNothing);
    expect(fakeWebViewControllerCreationCount, controllerCountBeforeFocus);

    expect(find.byKey(const ValueKey('exit-focus-mode-button')), findsNothing);

    await tester.dragFrom(const Offset(0, 320), const Offset(280, 0));
    await tester.pumpAndSettle();
    expect(find.text('Show controls'), findsOneWidget);
    expect(find.byKey(const ValueKey('show-controls-drawer-action')),
        findsOneWidget);
    expect(find.bySemanticsLabel('Show controls'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('show-controls-drawer-action')))
          .height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.text('Show controls'));
    await tester.pumpAndSettle();

    expect(activeBrowserStackIndex(tester), 1);
    expect(find.byTooltip('Exit Focus Mode'), findsNothing);
    expect(find.byTooltip('Enter Focus Mode'), findsOneWidget);
    expect(find.byTooltip('Open menu'), findsOneWidget);
    expect(find.byTooltip('Profile'), findsOneWidget);
    expect(find.bySemanticsLabel('Enter Focus Mode'), findsOneWidget);
    expect(find.text('New Tab'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('browser-mobile-tab-count')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(fakeWebViewControllerCreationCount, controllerCountBeforeFocus);

    await tester.tap(find.byTooltip('Enter Focus Mode'));
    await tester.pump();
    expect(find.byTooltip('Exit Focus Mode'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    installFakeWebViewPlatform();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: ShellHome(
          config: config,
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enter Focus Mode'), findsOneWidget);
    expect(find.byTooltip('Exit Focus Mode'), findsNothing);
    semantics.dispose();
  });

  testWidgets(
      'macOS menu command opens the existing drawer without resetting browser state',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ShellHome(
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onConfigChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New tab'));
      await tester.pump();
      expect(activeBrowserStackIndex(tester), 1);
      expect(fakeWebViewControllerCreationCount, 2);

      await tester.tap(find.byTooltip('Enter Focus Mode'));
      await tester.pump();
      expect(find.byTooltip('Open menu'), findsNothing);

      Future<void> invokeNativeMenuCommand() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          macOSMenuChannelName,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(showWingmanMenuMethod),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await invokeNativeMenuCommand();
      expect(find.text('Nostr Browser'), findsOneWidget);
      expect(find.text('Show controls'), findsOneWidget);
      expect(activeBrowserStackIndex(tester), 1);
      expect(fakeWebViewControllerCreationCount, 2);

      await invokeNativeMenuCommand();
      expect(find.text('Nostr Browser'), findsOneWidget);
      expect(activeBrowserStackIndex(tester), 1);
      expect(fakeWebViewControllerCreationCount, 2);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Focus Mode keeps web content inside device safe areas',
      (tester) async {
    const safePadding = EdgeInsets.fromLTRB(8, 44, 8, 34);
    final config = AppConfig.defaults().copyWith(
      deviceSecret: 'nsec-placeholder',
      deviceNpub: 'npub-safe-area',
      devicePublicKeyHex: 'abcdef',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: safePadding),
          child: ShellHome(
            config: config,
            bridge: NativeCoreBridge(),
            signerStore: SignerStore(),
            onConfigChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Enter Focus Mode'));
    await tester.pump();

    final webViewStack = find.byType(IndexedStack).last;
    final webViewRect = tester.getRect(webViewStack);
    expect(webViewRect.top, safePadding.top);
    expect(webViewRect.left, safePadding.left);
    expect(
      webViewRect.bottom,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Wingman browser saves and publishes Nostr profile',
      (tester) async {
    final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
    final config = AppConfig.defaults().copyWith(
      deviceSecret: identity.nsec,
      deviceNpub: identity.npub,
      devicePublicKeyHex: identity.publicKeyHex,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: config,
          profileRelayClient: _AcceptProfileRelays(),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();

    final displayNameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Display name',
    );
    expect(displayNameField, findsOneWidget);

    await tester.enterText(displayNameField, 'Example User');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Example User'), findsNothing);
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Example User'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Example User'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    installFakeWebViewPlatform();

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: config,
          profileRelayClient: _AcceptProfileRelays(),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Example User'), findsNothing);
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Example User'), findsOneWidget);
  });

  testWidgets('experimental Drive UI defaults off and persists opt-in',
      (tester) async {
    const experimentLabel =
        'Display experimental future Flight Deck Drive sync';
    Future<Finder> findExperimentCheckbox() async {
      await tester.drag(
        find.byType(ListView).last,
        const Offset(0, -3000),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      return find.widgetWithText(CheckboxListTile, experimentLabel);
    }

    await tester.pumpWidget(
      const WingmanApp(useSignerVault: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();

    final experimentCheckbox = await findExperimentCheckbox();
    expect(experimentCheckbox, findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(experimentCheckbox).value,
      isFalse,
    );
    expect(find.text('Trusted origins'), findsOneWidget);
    expect(find.text('Remember NIP-98 approvals'), findsOneWidget);
    expect(find.text('Tower URL'), findsNothing);
    expect(find.text('Flight Deck App npub'), findsNothing);
    await tester.scrollUntilVisible(find.text('Flight Deck URL'), -250,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    expect(find.text('Flight Deck URL'), findsOneWidget);
    expect(find.text('Workspace ID'), findsNothing);
    expect(find.text('Workspace service npub'), findsNothing);
    expect(find.text('Default Channel ID'), findsNothing);
    expect(find.text('Registration signer key'), findsNothing);
    expect(find.text('Register device'), findsNothing);
    expect(find.text('Validate channel'), findsNothing);

    await findExperimentCheckbox();
    await tester.ensureVisible(experimentCheckbox);
    await tester.tap(experimentCheckbox);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Tower URL'), -250,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    final flightDeckField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Flight Deck URL',
    );
    expect(flightDeckField, findsOneWidget);

    final towerField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Tower URL',
    );
    expect(towerField, findsOneWidget);

    await tester.enterText(towerField, 'https://tower.example');
    await tester.enterText(flightDeckField, 'https://example.com/flightdeck');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    installFakeWebViewPlatform();

    await tester.pumpWidget(
      const WingmanApp(useSignerVault: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();

    final restoredField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Flight Deck URL',
      ),
    );
    final restoredTowerField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Tower URL',
      ),
    );
    expect(restoredField.controller?.text, 'https://example.com/flightdeck');
    expect(restoredTowerField.controller?.text, 'https://tower.example');
    final restoredExperimentCheckbox = await findExperimentCheckbox();
    expect(
      tester.widget<CheckboxListTile>(restoredExperimentCheckbox).value,
      isTrue,
    );
    expect(fakeLoadedRequestUrls,
        isNot(contains('https://example.com/flightdeck')));

    await tester.ensureVisible(restoredExperimentCheckbox);
    await tester.tap(restoredExperimentCheckbox);
    await tester.pumpAndSettle();
    expect(find.text('Tower URL'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    installFakeWebViewPlatform();
    await tester.pumpWidget(
      const WingmanApp(useSignerVault: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();

    final disabledExperimentCheckbox = await findExperimentCheckbox();
    expect(
      tester.widget<CheckboxListTile>(disabledExperimentCheckbox).value,
      isFalse,
    );
    await tester.ensureVisible(disabledExperimentCheckbox);
    await tester.tap(disabledExperimentCheckbox);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Tower URL'), -250,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    final preservedFlightDeckField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Flight Deck URL',
      ),
    );
    final preservedTowerField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Tower URL',
      ),
    );
    expect(
      preservedFlightDeckField.controller?.text,
      'https://example.com/flightdeck',
    );
    expect(preservedTowerField.controller?.text, 'https://tower.example');
  });

  testWidgets(
      'configured Tower registration is explicit without enabling experimental Drive',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ShellHome(
      config: AppConfig.defaults().copyWith(
          towerUrl: 'https://tower.example',
          workspaceServiceNpub: 'npub-service',
          deviceNpub: 'npub-device'),
      bridge: NativeCoreBridge(),
      signerStore: SignerStore(),
      onConfigChanged: (_) {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Register device'), 250,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    expect(find.text('Register device'), findsOneWidget);
    expect(
        find.textContaining(
            'Optional Tower device registration: https://tower.example'),
        findsOneWidget);
    expect(find.text('Tower URL'), findsNothing);
    final identityFinder = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Device npub');
    await tester.scrollUntilVisible(identityFinder, -250,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    final identityField = tester.widget<TextField>(identityFinder);
    expect(identityField.readOnly, isTrue);
    expect(identityField.controller!.text, 'npub-device');
  });

  testWidgets('legacy saved configuration keeps experimental Drive UI off',
      (tester) async {
    await SharedPreferencesAsync().setString(
      'wingman.app.config.v1',
      '{"version":1,"tower_url":"https://legacy-tower.example"}',
    );

    await tester.pumpWidget(const WingmanApp(useSignerVault: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(ListView).last,
      const Offset(0, -3000),
    );
    await tester.pumpAndSettle();

    final experimentCheckbox = find.widgetWithText(
      CheckboxListTile,
      'Display experimental future Flight Deck Drive sync',
    );
    expect(
      tester.widget<CheckboxListTile>(experimentCheckbox).value,
      isFalse,
    );
    expect(find.text('Tower URL'), findsNothing);
  });

  testWidgets(
      'Shared-folder Drive navigation is available independent of legacy sync setting',
      (tester) async {
    Future<void> openDrawer() async {
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults(),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openDrawer();
    expect(find.text('Drive'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    installFakeWebViewPlatform();
    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            displayExperimentalFlightDeckDriveSync: true,
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openDrawer();
    expect(find.text('Drive'), findsOneWidget);
  });

  testWidgets('first launch opens create and import from the browser avatar',
      (tester) async {
    await tester.pumpWidget(
      WingmanApp(
        signerVault: SignerVault(
          localStore: MemorySignerVaultLocalStore(),
          secretStore: MemorySignerVaultSecretStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Profile'), findsOneWidget);
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create identity / Import key'));
    await tester.pumpAndSettle();
    expect(find.text('Set Up Nostr Browser'), findsOneWidget);
    expect(find.text('Create identity'), findsOneWidget);
    await tester.tap(find.text('Import key'));
    await tester.pumpAndSettle();
    expect(find.text('Nostr private key'), findsOneWidget);
    expect(find.text('PIN'), findsOneWidget);
    expect(find.text('Confirm PIN'), findsOneWidget);
  });

  testWidgets('logging out asks for confirmation and locks the signer',
      (tester) async {
    var loggedOut = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ShellHome(
          config: AppConfig.defaults().copyWith(
            deviceSecret: 'nsec-placeholder',
            deviceNpub: 'npub-logout',
            devicePublicKeyHex: 'abcdef',
          ),
          bridge: NativeCoreBridge(),
          signerStore: SignerStore(),
          onConfigChanged: (_) {},
          onLogOut: () => loggedOut = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(find.text('Log out?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(loggedOut, isTrue);
  });
}

FlightDeckUpdateSnapshot _flightDeckSnapshot({
  required FlightDeckUpdatePhase phase,
  required String active,
}) {
  return FlightDeckUpdateSnapshot(
    phase: phase,
    packagedVersion: 'Build 100 (packaged)',
    activeVersion: active,
    previousVersion: '',
    availableVersion: '',
    failedVersion: '',
    message: phase.name,
    error: '',
    lastCheckAt: DateTime.utc(2026, 9, 11),
    lastSuccessAt: null,
    lastFailureAt: null,
    enabled: true,
    busy: false,
  );
}

class _ShellFlightDeckUpdateController extends FlightDeckUpdateController {
  _ShellFlightDeckUpdateController(this._snapshot);

  FlightDeckUpdateSnapshot _snapshot;

  @override
  String? get activeRootPath => null;

  @override
  FlightDeckUpdateSnapshot get snapshot => _snapshot;

  void activate(String version) {
    _snapshot = _flightDeckSnapshot(
      phase: FlightDeckUpdatePhase.active,
      active: version,
    );
    notifyListeners();
  }

  void republish() {
    notifyListeners();
  }

  @override
  Future<void> applyAvailable() async {}

  @override
  Future<void> checkForUpdates({bool applyAutomatically = false}) async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<void> reportServeFailure(String message) async {}

  @override
  Future<void> rollback() async {}
}
