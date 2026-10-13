import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
      'legacy apps have no startup stars; settings validate and isolate identities',
      () async {
    final preferences = SharedPreferencesAsync();
    final store = BrowserBookmarkStore(preferences: preferences);
    await preferences.setString(
        '${BrowserBookmarkStore.keyPrefix}npub-a',
        jsonEncode({
          'version': 1,
          'bookmarks': [
            {'title': 'Legacy', 'url': 'https://example.com/'},
            {
              'title': 'Malformed',
              'url': 'https://other.example/',
              'startup': 'true'
            }
          ]
        }));
    expect((await store.load('npub-a')).every((b) => !b.startup), isTrue);
    expect(await store.loadBuiltInStartup('npub-a'), isFalse);
    expect(await store.loadLabelColour('npub-a'), '#ffffff');
    await store.saveBuiltInStartup('npub-a', true);
    await store.saveLabelColour('npub-a', '#ABCDEF');
    final relaunched = BrowserBookmarkStore();
    expect(await relaunched.loadBuiltInStartup('npub-a'), isTrue);
    expect(await relaunched.loadLabelColour('npub-a'), '#abcdef');
    expect(await relaunched.loadBuiltInStartup('npub-b'), isFalse);
    expect(await relaunched.loadLabelColour('npub-b'), '#ffffff');
    for (final value in ['red', '#fff', '#ffffff;display:none', '#ffffff00']) {
      await preferences.setString(
          '${BrowserBookmarkStore.keyPrefix}npub-a.labelColour', value);
      expect(await store.loadLabelColour('npub-a'), '#ffffff');
    }
  });

  test('startup selection persists with app edits and disappears on deletion',
      () async {
    final store = BrowserBookmarkStore();
    const original = BrowserBookmark(
        title: 'App', url: 'https://example.com/long', startup: true);
    await store.save('npub-a', [original.renamed('New name')]);
    expect(
        (await BrowserBookmarkStore().load('npub-a')).single.startup, isTrue);
    const edited = BrowserBookmark(
        title: 'New name', url: 'https://example.com/short', startup: true);
    await store.save('npub-a', [edited]);
    final saved = (await BrowserBookmarkStore().load('npub-a')).single;
    expect(saved.url, edited.url);
    expect(saved.startup, isTrue);
    await store.save('npub-a', []);
    expect(await BrowserBookmarkStore().load('npub-a'), isEmpty);
  });

  test('canonicalization only normalizes whitespace and scheme/host casing',
      () {
    expect(
      canonicalBrowserBookmarkUrl(' HTTPS://Example.COM/path/?b=2&a=1#part '),
      'https://example.com/path/?b=2&a=1#part',
    );
    expect(
      canonicalBrowserBookmarkUrl('https://example.com/path?b=2&a=1#part'),
      isNot(
        canonicalBrowserBookmarkUrl('https://example.com/path/?b=2&a=1#part'),
      ),
    );
    expect(canonicalBrowserBookmarkUrl('file:///tmp/page'), isNull);
    expect(canonicalBrowserBookmarkUrl('not a URL'), isNull);
  });

  test('bookmarks persist and reload for one signer', () async {
    final store = BrowserBookmarkStore();
    const bookmarks = [
      BrowserBookmark(title: 'Useful page', url: 'https://example.com/page'),
    ];

    await store.save('npub-example-user', bookmarks);

    expect(await BrowserBookmarkStore().load('npub-example-user'), hasLength(1));
    final restored = (await BrowserBookmarkStore().load('npub-example-user')).single;
    expect(restored.title, 'Useful page');
    expect(restored.url, 'https://example.com/page');
    expect(await store.load('npub-someone-else'), isEmpty);
  });

  test('renaming trims the title while preserving bookmark identity', () async {
    final store = BrowserBookmarkStore();
    const original = BrowserBookmark(
      title: 'Original title',
      url: 'https://example.com/page',
    );
    final renamed = original.renamed('  Better title  ');

    expect(renamed.title, 'Better title');
    expect(renamed.url, original.url);
    expect(original.renamed('   ').title, original.title);

    await store.save('npub-example-user', [renamed]);
    final restored = (await BrowserBookmarkStore().load('npub-example-user')).single;
    expect(restored.title, 'Better title');
    expect(restored.url, original.url);
  });

  test('thumbnail precedence and background are persisted and identity scoped',
      () async {
    final store = BrowserBookmarkStore();
    final image = 'data:image/png;base64,${base64Encode([
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10
        ])}';
    final app = BrowserBookmark(
        title: 'App',
        url: 'https://example.com/?keep=1#part',
        iconUrl: 'https://example.com/icon.png',
        customImage: image);
    await store.save('npub-a', [app]);
    await store.saveBackground('npub-a', image);
    final restored = (await store.load('npub-a')).single;
    expect(restored.thumbnail, image);
    expect(restored.url, app.url);
    expect(restored.iconUrl, app.iconUrl);
    expect(await store.loadBackground('npub-a'), image);
    expect(await store.loadBackground('npub-b'), isNull);
    await store.saveBackground('npub-a', null);
    expect(await store.loadBackground('npub-a'), isNull);
  });

  test('metadata cannot become a service endpoint or script', () {
    expect(safeBookmarkIconUrl('https://peer.fips/icon.png'), isNull);
    expect(safeBookmarkIconUrl('http://remote.example/icon.png'), isNull);
    expect(safeBookmarkIconUrl('javascript:alert(1)'), isNull);
    expect(safeBookmarkImage('data:image/svg+xml,<svg/>'), isNull);
    expect(safeBookmarkImage('data:image/png;base64,broken'), isNull);
    expect(safeBookmarkIconUrl('http://127.0.0.1:47831/icon.png'), isNotNull);
    expect(
        canonicalBrowserBookmarkUrl('https://user:pass@example.com'), isNull);
    expect(canonicalBrowserBookmarkUrl('https://example.com/a b'), isNull);
    const app = BrowserBookmark(
        title: 'Legacy', url: 'https://example.com/path?private=1');
    expect(app.thumbnail, 'https://example.com/favicon.ico');
    expect(app.renamed('New').url, app.url);
  });

  test('corrupt and stale entries are ignored and duplicates are removed',
      () async {
    final preferences = SharedPreferencesAsync();
    final store = BrowserBookmarkStore(preferences: preferences);
    await preferences.setString(
      '${BrowserBookmarkStore.keyPrefix}npub-corrupt',
      jsonEncode({
        'bookmarks': [
          {'title': 'First', 'url': 'HTTPS://Example.COM/page?x=1'},
          {'title': 'Duplicate', 'url': 'https://example.com/page?x=1'},
          {'title': 'Bad', 'url': 'javascript:alert(1)'},
          {'title': '', 'url': 'https://fallback.example/path'},
          'stale',
        ],
      }),
    );

    final bookmarks = await store.load('npub-corrupt');

    expect(bookmarks, hasLength(2));
    expect(bookmarks.first.title, 'First');
    expect(bookmarks.last.title, 'fallback.example');

    await preferences.setString(
      '${BrowserBookmarkStore.keyPrefix}npub-corrupt',
      '{not-json',
    );
    expect(await store.load('npub-corrupt'), isEmpty);
  });
}
