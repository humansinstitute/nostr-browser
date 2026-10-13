import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/browser_app_selector.dart';
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
  test('render fixture with bundled default background', () async {
    final data = await rootBundle.load('assets/app-selector/voxel-beach.png');
    final image =
        'data:image/png;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
    expect(safeBookmarkImage(image), isNotNull);
    final html = browserAppSelectorHtml(
        builtInUrl: 'http://127.0.0.1:47831/',
        backgroundImage: image,
        savedBookmarks: [
          const BrowserBookmark(
              title: 'Flight Deck', url: 'http://127.0.0.1:47831/'),
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
    expect(html, isNot(contains('aria-label="Remove Flight Deck"')));
  });
}
