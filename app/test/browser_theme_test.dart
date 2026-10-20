import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/nostr_profile_relay_client.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'package:wingman_app/src/features/setup/setup_screen.dart';
import 'package:wingman_app/src/theme/browser_theme.dart';
import 'fake_webview_platform.dart';

final config = AppConfig.defaults().copyWith(
  deviceNpub: 'preview-identity',
  deviceSecret: 'test-placeholder',
  flightDeckUrl: 'https://reader.example/',
  towerUrl: '',
);

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['BROWSER_THEME_EVIDENCE_DIRECTORY'];
  if (directory == null) return;
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('theme-capture')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(directory)..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final fonts = Platform.environment['BROWSER_THEME_FONT_DIRECTORY'];
    if (fonts == null) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(Future.value(ByteData.sublistView(
          File('$fonts/${entry.value}').readAsBytesSync())));
      await loader.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
  });

  test('reading and chrome text retain accessible contrast', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
    }

    final theme = BrowserTheme.light();
    expect(contrast(BrowserTheme.ink, BrowserTheme.paper), greaterThan(7));
    expect(contrast(BrowserTheme.lavender, BrowserTheme.activeTab),
        greaterThan(7));
    expect(contrast(const Color(0xFFAA95BA), BrowserTheme.frame),
        greaterThan(4.5));
    expect(contrast(theme.colorScheme.error, BrowserTheme.paper),
        greaterThan(4.5));
    expect(contrast(Colors.white, BrowserTheme.purple), greaterThan(4.5));
  });

  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets('production chrome, menus, signing and settings at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget host(Widget child) => RepaintBoundary(
          key: const ValueKey('theme-capture'),
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: BrowserTheme.light(),
              home: Scaffold(body: child)));
      final browser = BrowserScreen(
        config: config,
        bridge: NativeCoreBridge(),
        signerStore: SignerStore(),
        profileRelayClient: NostrProfileRelayClient(relays: const []),
        onOpenDrawer: () {},
        onOpenSetup: () {},
        onOpenSigner: () {},
        onOpenStatus: () {},
      );
      await tester.pumpWidget(host(browser));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('New Tab'));
      await tester.pumpAndSettle();
      final address = tester.widget<TextField>(find.byType(TextField).first);
      expect(address.style!.color, BrowserTheme.ink);
      await capture(tester, 'chrome-${width.toInt()}');
      await tester.tap(find.byType(TextField).first);
      await tester.enterText(
          find.byType(TextField).first, 'https://reader.example/');
      await tester.pump(const Duration(milliseconds: 250));
      expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .focusNode!
              .hasFocus,
          isTrue);
      await capture(tester, 'address-focus-${width.toInt()}');
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode!
          .unfocus();
      await tester.pumpAndSettle();
      if (width >= 600) {
        final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
        await mouse.down(tester.getCenter(find.text('New Tab')));
        await mouse.up();
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(find.text('Set tab prefix…'), findsOneWidget);
        await capture(tester, 'tab-menu-${width.toInt()}');
        await tester.tapAt(const Offset(8, 800));
        await tester.pumpAndSettle();
      } else {
        expect(find.byKey(const ValueKey('browser-mobile-tab-count')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('browser-tab-strip')), findsNothing);
      }
      await tester.tap(find.byTooltip('Profile'));
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);
      await capture(tester, 'avatar-menu-${width.toInt()}');
      final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.addPointer(location: const Offset(0, 0));
      await hover.moveTo(tester.getCenter(find.text('Setup')));
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'menu-hover-${width.toInt()}');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 250));
      await capture(tester, 'menu-keyboard-${width.toInt()}');
      await hover.removePointer();
      await tester.tapAt(const Offset(8, 800));
      await tester.pumpAndSettle();
      // Trigger the real signing dialog using the browser's native message path.
      submitFakePageFinished(
          controllerIndex: 0, url: 'https://reader.example/');
      await tester.pumpAndSettle();
      final script = fakeExecutedJavaScripts
          .lastWhere((s) => s.contains('const signerDocumentToken ='));
      final token = jsonDecode(RegExp(r'const signerDocumentToken = (.*);')
          .firstMatch(script)!
          .group(1)!);
      submitFakeJavaScriptMessage(
          controllerIndex: 0,
          channel: 'WingmanSigner',
          message: jsonEncode({
            'id': 'theme-sign',
            'method': 'signEvent',
            'signerDocumentToken': token,
            'params': {
              'kind': 1,
              'tags': [],
              'content': 'A small note from the reading room.'
            }
          }));
      await tester.pumpAndSettle();
      expect(find.text('Approve Nostr event signature'), findsOneWidget);
      await capture(tester, 'signing-${width.toInt()}');
      await tester.tap(find.text('Reject', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(SetupScreen(
        config: config,
        bridge: NativeCoreBridge(),
        fipsRuntime: FipsRuntimeService(
            isMacOS: false, isLinux: false, isAndroid: false, isIOS: false),
        onConfigChanged: (_) {},
        onClearBrowserData: () async {},
        onOpenFipsApp: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'settings-${width.toInt()}');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
