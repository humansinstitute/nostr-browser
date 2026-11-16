import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/browser_app_selector.dart';
import 'package:wingman_app/src/features/browser/grasp_android_channel.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('tiles escape untrusted labels and preserve the complete launch URL',
      () {
    final html = browserAppSelectorHtml(savedBookmarks: const [
      BrowserBookmark(
          title: '<script>"&', url: 'https://example.com/?keep=1&other=2#part')
    ]);
    expect(html, contains('&lt;script&gt;&quot;&amp;'));
    expect(html,
        contains('data-url="https://example.com/?keep=1&amp;other=2#part"'));
    expect(html, contains('referrerpolicy="no-referrer"'));
    expect(html, contains("connect-src 'none'"));
  });
  test('actual default selector fits native home bound, exceeds message bound',
      () async {
    final data = await rootBundle.load('assets/app-selector/voxel-beach.png');
    final image =
        'data:image/png;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
    final html = browserAppSelectorHtml(
        backgroundImage: image, savedBookmarks: const []);
    final nativePolicy = File(
            'android/app/src/main/kotlin/com/wingmanbefree/wingman_app/grasp/NativeHomeHtmlPolicy.kt')
        .readAsStringSync();
    final limit = int.parse(RegExp(r'MAX_HTML_LENGTH = ([0-9_]+)')
        .firstMatch(nativePolicy)!
        .group(1)!
        .replaceAll('_', ''));
    expect(html.length, greaterThan(1500000));
    expect(html.length, lessThanOrEqualTo(limit));
    expect(html, contains(image));
    const channel = MethodChannel('wingman/grasp_android');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'loadHomeHtml');
      expect(call.arguments['webViewIdentifier'], 42);
      expect(call.arguments['html'], html);
      return null;
    });
    try {
      await GraspAndroidChannel.loadHomeHtml(webViewIdentifier: 42, html: html);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('render fixture with bundled default background', () async {
    final data = await rootBundle.load('assets/app-selector/voxel-beach.png');
    final image =
        'data:image/png;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
    expect(safeBookmarkImage(image), isNotNull);
    final html =
        browserAppSelectorHtml(backgroundImage: image, savedBookmarks: [
      const BrowserBookmark(title: 'Flight Deck', url: 'https://deck.example/'),
      const BrowserBookmark(
          title: 'Autopilot', url: 'https://autopilot.example/home'),
      const BrowserBookmark(
          title: 'Solvitur Ambulando',
          url:
              'https://apps.example/deck?workspace=deliberately-long-route&scope=keep-this#today'),
      const BrowserBookmark(
          title: 'Research', url: 'https://research.example/'),
      BrowserBookmark(
          title: 'Custom thumbnail',
          url: 'https://custom.example/',
          customImage: image),
      const BrowserBookmark(
          title: 'A readable longer app name',
          url: 'https://long-name.example/'),
    ]);
    final directory = Platform.environment['APP_SELECTOR_EVIDENCE_DIRECTORY'];
    if (directory != null) {
      final dir = Directory(directory)..createSync(recursive: true);
      File('${dir.path}/selector.html').writeAsStringSync(html);
      File('${dir.path}/discovery.js')
          .writeAsStringSync(bookmarkDiscoveryScript);
    }
    expect(html, contains('background-image:'));
    expect(html, contains('aria-label="Remove Flight Deck"'));
  });
}
