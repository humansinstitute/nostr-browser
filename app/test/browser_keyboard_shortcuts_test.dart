import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/browser/browser_keyboard_shortcuts.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/embedded_content_focus.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';

import 'fake_webview_platform.dart';

void main() {
  late GlobalKey<BrowserScreenState> key;
  late int menus;
  late BuildContext shellContext;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
    key = GlobalKey<BrowserScreenState>();
    menus = 0;
  });
  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      shellContext = context;
      return Scaffold(
          body: BrowserScreen(
        key: key,
        config: AppConfig.defaults(),
        bridge: NativeCoreBridge(),
        signerStore: SignerStore(),
        onOpenDrawer: () => menus++,
        onOpenSetup: () {},
        onOpenSigner: () {},
        onOpenStatus: () {},
      ));
    })));
    await tester.pumpAndSettle();
  }

  int active(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byType(IndexedStack).first).index!;
  Future<void> command(WidgetTester tester, LogicalKeyboardKey arrow) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(arrow);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'next app wraps, menu opens, repeats and extra modifiers do not cycle',
      (tester) async {
    await pumpBrowser(tester);
    await command(tester, LogicalKeyboardKey.arrowRight);
    expect(active(tester), 0);
    key.currentState!.openTab('https://one.example');
    key.currentState!.openTab('https://two.example');
    await tester.pumpAndSettle();
    final creations = fakeWebViewControllerCreationCount;
    final loads = List.of(fakeLoadedRequestUrls);
    for (final index in [0, 1, 2, 0]) {
      await command(tester, LogicalKeyboardKey.arrowRight);
      expect(active(tester), index);
    }
    await command(tester, LogicalKeyboardKey.arrowLeft);
    await command(tester, LogicalKeyboardKey.arrowLeft);
    expect(menus, 2);
    expect(active(tester), 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(active(tester), 1);
    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.controlLeft
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await command(tester, LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(modifier);
      expect(active(tester), 1);
    }
    expect(fakeWebViewControllerCreationCount, creations);
    expect(fakeLoadedRequestUrls, loads);
  });

  testWidgets('Flutter address editing and modal dialogs retain Command arrows',
      (tester) async {
    await pumpBrowser(tester);
    key.currentState!.openTab('https://one.example');
    await tester.pumpAndSettle();
    // Clicking the active desktop tab reveals the address field.
    await tester.tap(find.text('one.example').first);
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, 'two words');
    await command(tester, LogicalKeyboardKey.arrowRight);
    await command(tester, LogicalKeyboardKey.arrowLeft);
    expect(active(tester), 1);
    expect(menus, 0);
    expect(tester.widget<TextField>(field).controller!.text, 'two words');
    FocusManager.instance.primaryFocus?.unfocus();
    showDialog<void>(
        context: shellContext,
        builder: (_) => const AlertDialog(content: Text('Modal')));
    await tester.pumpAndSettle();
    await command(tester, LogicalKeyboardKey.arrowRight);
    await command(tester, LogicalKeyboardKey.arrowLeft);
    expect(active(tester), 1);
    expect(menus, 0);
  });

  testWidgets(
      'native page focus delegates Command arrows and preserves Ctrl+Tab',
      (tester) async {
    await pumpBrowser(tester);
    key.currentState!.openTab('https://one.example');
    await tester.pumpAndSettle();
    // Fake platform views have no native hit target. Request the same neutral
    // focus node used when a real native page receives a pointer event.
    tester
        .widgetList<Focus>(find.descendant(
          of: find.byType(EmbeddedContentFocus),
          matching: find.byType(Focus),
        ))
        .firstWhere((focus) =>
            focus.focusNode?.debugLabel == 'Embedded browser content')
        .focusNode!
        .requestFocus();
    await tester.pump();
    await command(tester, LogicalKeyboardKey.arrowRight);
    await command(tester, LogicalKeyboardKey.arrowLeft);
    expect(active(tester), 1);
    expect(menus, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(active(tester), 0);
  });

  test('export native keyboard script when evidence directory is requested',
      () {
    final directory = Platform.environment['KEYBOARD_EVIDENCE_DIR'];
    if (directory != null) {
      File('$directory/keyboard.js')
          .writeAsStringSync(browserKeyboardShortcutsScript);
    }
    expect(browserKeyboardShortcutsScript, contains('event.isTrusted'));
  });
}
