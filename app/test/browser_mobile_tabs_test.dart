import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'package:wingman_app/src/theme/browser_theme.dart';

import 'fake_webview_platform.dart';

void main() {
  late GlobalKey<BrowserScreenState> browserKey;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
    browserKey = GlobalKey<BrowserScreenState>();
  });

  Future<void> pumpBrowser(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool reducedMotion = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: BrowserTheme.light(),
        builder: reducedMotion
            ? (context, child) => MediaQuery(
                  data:
                      MediaQuery.of(context).copyWith(disableAnimations: true),
                  child: child!,
                )
            : null,
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
  }

  int activeStackIndex(WidgetTester tester) =>
      tester.widgetList<IndexedStack>(find.byType(IndexedStack)).last.index!;

  testWidgets('mobile header replaces the desktop scroller and updates count',
      (tester) async {
    await pumpBrowser(tester);

    expect(find.byKey(const ValueKey('browser-mobile-tab-header')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('browser-tab-strip')), findsNothing);
    expect(find.text('New Tab'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    browserKey.currentState!.openTab('https://one.example/path');
    browserKey.currentState!.openTab('https://two.example/path');
    await tester.pumpAndSettle();

    expect(find.text('3'), findsOneWidget);
    expect(find.text('two.example'), findsOneWidget);
  });

  testWidgets('mobile title and count retain contrast on purple chrome',
      (tester) async {
    double contrast(Color foreground, Color background) {
      final foregroundLuminance = foreground.computeLuminance();
      final backgroundLuminance = background.computeLuminance();
      final lighter = foregroundLuminance > backgroundLuminance
          ? foregroundLuminance
          : backgroundLuminance;
      final darker = foregroundLuminance > backgroundLuminance
          ? backgroundLuminance
          : foregroundLuminance;
      return (lighter + 0.05) / (darker + 0.05);
    }

    await pumpBrowser(tester);

    final header = tester.widget<Material>(
      find.byKey(const ValueKey('browser-mobile-tab-header')),
    );
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('browser-mobile-tab-title')),
    );
    final count = tester.widget<OutlinedButton>(
      find
          .descendant(
            of: find.byKey(const ValueKey('browser-mobile-tab-count')),
            matching: find.byType(OutlinedButton),
          )
          .first,
    );
    final enabledCountColor = count.style!.foregroundColor!.resolve({})!;
    final disabledCountColor = count.style!.foregroundColor!.resolve(
      {WidgetState.disabled},
    )!;

    expect(header.color, BrowserTheme.frame);
    expect(title.style!.color, BrowserTheme.lavender);
    expect(contrast(title.style!.color!, header.color!), greaterThan(4.5));
    expect(contrast(enabledCountColor, header.color!), greaterThan(4.5));
    expect(contrast(disabledCountColor, header.color!), greaterThan(4.5));
  });

  testWidgets('tab count control renders zero, one, and many states',
      (tester) async {
    Future<void> pumpCount(int count) => tester.pumpWidget(
          MaterialApp(
            home: BrowserTabCountButton(count: count, onPressed: () {}),
          ),
        );

    await pumpCount(0);
    expect(find.text('0'), findsOneWidget);
    await pumpCount(1);
    expect(find.text('1'), findsOneWidget);
    await pumpCount(12);
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets('overview selects and closes tabs without recreating controllers',
      (tester) async {
    await pumpBrowser(tester);
    browserKey.currentState!.openTab('https://one.example/path');
    browserKey.currentState!.openTab('https://two.example/path');
    await tester.pumpAndSettle();
    final controllers = fakeWebViewControllerCreationCount;
    final loads = List<String>.of(fakeLoadedRequestUrls);

    await tester.tap(find.byKey(const ValueKey('browser-mobile-tab-count')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-mobile-tab-overview')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('tab-overview-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-overview-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-overview-3')), findsOneWidget);
    final activeShape = tester
        .widget<Material>(
          find
              .descendant(
                of: find.byKey(const ValueKey('tab-overview-3')),
                matching: find.byType(Material),
              )
              .first,
        )
        .shape! as RoundedRectangleBorder;
    expect(activeShape.side.width, 3);

    await tester.tap(find.byKey(const ValueKey('tab-overview-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-mobile-tab-overview')),
        findsNothing);
    expect(activeStackIndex(tester), 1);

    await tester.tap(find.byKey(const ValueKey('browser-mobile-tab-count')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close one.example'));
    await tester.pumpAndSettle();
    expect(find.text('Tabs (2)'), findsOneWidget);
    final nextActiveShape = tester
        .widget<Material>(
          find
              .descendant(
                of: find.byKey(const ValueKey('tab-overview-1')),
                matching: find.byType(Material),
              )
              .first,
        )
        .shape! as RoundedRectangleBorder;
    expect(nextActiveShape.side.width, 3);
    expect(fakeWebViewControllerCreationCount, controllers);
    expect(fakeLoadedRequestUrls, loads);
  });

  testWidgets('closing the last tab in overview creates a fresh home tab',
      (tester) async {
    await pumpBrowser(tester);
    expect(fakeWebViewControllerCreationCount, 1);

    await tester.tap(find.byKey(const ValueKey('browser-mobile-tab-count')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close New Tab'));
    await tester.pumpAndSettle();

    expect(find.text('Tabs (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-overview-2')), findsOneWidget);
    expect(fakeWebViewControllerCreationCount, 2);
    await tester.tap(find.byTooltip('Close tab overview'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('New Tab'), findsOneWidget);
  });

  testWidgets('long mobile title is constrained in header and overview',
      (tester) async {
    await pumpBrowser(tester);
    browserKey.currentState!.openTab('https://long.example/path');
    await tester.pumpAndSettle();
    final longTitle = List.filled(20, 'A long page title').join(' ');
    submitFakeJavaScriptMessage(
      controllerIndex: 1,
      channel: 'WingmanTitle',
      message: longTitle,
    );
    await tester.pump();

    final headerTitle = tester.widget<Text>(
      find.byKey(const ValueKey('browser-mobile-tab-title')),
    );
    expect(headerTitle.maxLines, 1);
    expect(headerTitle.overflow, TextOverflow.ellipsis);

    await tester.tap(find.byKey(const ValueKey('browser-mobile-tab-count')));
    await tester.pumpAndSettle();
    final overviewTitles = tester.widgetList<Text>(find.text(longTitle));
    expect(overviewTitles, isNotEmpty);
    expect(overviewTitles.every((text) => text.maxLines == 1), isTrue);
  });

  testWidgets('refresh feedback starts immediately and ignores stale callbacks',
      (tester) async {
    await pumpBrowser(tester, reducedMotion: true);
    browserKey.currentState!.openTab('https://refresh.example/page');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('browser-mobile-current-tab')),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('browser-reload-button')));
    await tester.tap(find.byKey(const ValueKey('browser-reload-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-tab-loading')), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsWidgets);

    submitFakePageStarted(
      controllerIndex: 1,
      url: 'https://refresh.example/page',
    );
    submitFakePageStarted(
      controllerIndex: 1,
      url: 'https://refresh.example/page',
    );
    submitFakePageFinished(
      controllerIndex: 1,
      url: 'https://refresh.example/page',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-tab-loading')), findsOneWidget);

    submitFakeWebResourceError(
      controllerIndex: 1,
      error: const WebResourceError(
        errorCode: -1,
        description: 'failed',
        isForMainFrame: true,
        url: 'https://refresh.example/page',
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-tab-loading')), findsNothing);
    expect(find.byTooltip('Reload'), findsOneWidget);
  });

  testWidgets('desktop keeps the reorderable tab strip', (tester) async {
    await pumpBrowser(tester, size: const Size(900, 700));

    expect(find.byKey(const ValueKey('browser-tab-strip')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('browser-mobile-tab-header')), findsNothing);
    expect(find.byTooltip('New tab'), findsOneWidget);
  });
}
