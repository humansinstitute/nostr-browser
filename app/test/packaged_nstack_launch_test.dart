import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/nstack_shell_catalogue.dart';
import 'package:wingman_app/src/core/packaged_nstack_shell.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';
import 'package:wingman_app/src/features/browser/signer_store.dart';
import 'fake_webview_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('shipped Flutter package matches the compiled catalogue pin', () async {
    final shell =
        await PackagedNStackShell.fromBundle(nstackShellManifestSha256);
    expect(shell.sourceRevision, matches(RegExp(r'^[a-f0-9]{40}$')));
    await shell.close();
  });
  testWidgets(
      'native home launches known package; rejects remote and subframe navigation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    installFakeWebViewPlatform();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BrowserScreen(
      config: AppConfig.defaults().copyWith(deviceNpub: 'npub-package-test'),
      bridge: NativeCoreBridge(),
      signerStore: SignerStore(),
      onOpenDrawer: () {},
      onOpenSetup: () {},
      onOpenSigner: () {},
      onOpenStatus: () {},
      onPrepareFipsNavigation: (_) async => null,
    ))));
    await tester.pumpAndSettle();
    expect(
        fakeLoadedHtmlStrings.last, contains('data-action="openNStackShell"'));
    final controllerIndex = fakeWebViewControllerCreationCount - 1;
    submitFakeJavaScriptMessage(
        controllerIndex: controllerIndex,
        channel: 'WingmanSigner',
        message: jsonEncode({'id': 'launch', 'method': 'openNStackShell'}));
    for (var n = 0; n < 100 && fakeLoadedRequestUrls.isEmpty; n++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
    expect(fakeLoadedRequestUrls, isNotEmpty,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '));
    final uri = Uri.parse(fakeLoadedRequestUrls.last);
    expect(uri.host, '127.0.0.1');
    final snapshot = await SharedPreferencesAsync()
        .getString('wingman.browser.tabs.v3.npub-package-test');
    expect(snapshot, isNot(contains(uri.toString())));
    expect((jsonDecode(snapshot!)['tabs'] as List).single['is_home'], isTrue);
    expect(uri.path, matches(RegExp(r'^/[A-Za-z0-9_-]{43}/index.html$')));
    expect(fakeExecutedJavaScripts.any((s) => s.contains("'fipsTransport'")),
        isTrue);
    expect(
        await submitFakeNavigationRequest(
            controllerIndex: controllerIndex,
            url: 'https://attacker.example',
            isMainFrame: true),
        NavigationDecision.prevent);
    expect(
        await submitFakeNavigationRequest(
            controllerIndex: controllerIndex,
            url: uri.toString(),
            isMainFrame: false),
        NavigationDecision.prevent);
    expect(
        await submitFakeNavigationRequest(
            controllerIndex: controllerIndex,
            url: '$uri#connect',
            isMainFrame: true),
        NavigationDecision.navigate);
    fakeExecutedJavaScripts.clear();
    submitFakePageFinished(
        controllerIndex: controllerIndex, url: 'https://attacker.example');
    await tester.pumpAndSettle();
    expect(fakeExecutedJavaScripts.any((s) => s.contains("'fipsTransport'")),
        isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isMacOS);
}
