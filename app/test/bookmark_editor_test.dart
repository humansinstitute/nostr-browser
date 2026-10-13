import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/bookmark_editor.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';

const original = BrowserBookmark(
    title: 'App',
    startup: true,
    url: 'https://example.com/long?keep=1#section',
    iconUrl: 'https://example.com/icon.png');
const other = BrowserBookmark(title: 'Other', url: 'https://example.com/short');
void main() {
  Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);
  Future<void> open(WidgetTester tester, ValueChanged<BrowserBookmark?> result,
      {Future<String?> Function()? pick}) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async => result(await showDialog<BrowserBookmark>(
                    context: context,
                    builder: (_) => BookmarkEditor(
                        bookmark: original,
                        bookmarks: const [original, other],
                        pickImage: pick))),
                child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('validates name, actual URL and duplicate without losing draft',
      (tester) async {
    BrowserBookmark? result;
    await open(tester, (value) => result = value);
    await tester.enterText(field('App name'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an app name.'), findsOneWidget);
    await tester.enterText(field('App name'), ' Short app ');
    await tester.enterText(field('Launch URL'), 'javascript:alert(1)');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('complete HTTP'), findsOneWidget);
    await tester.enterText(field('Launch URL'), other.url);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('An app with this launch URL is already saved.'),
        findsOneWidget);
    await tester.enterText(
        field('Launch URL'), 'https://example.com/intentional?x=2#part');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.url, 'https://example.com/intentional?x=2#part');
    expect(result!.title, 'Short app');
    expect(result!.startup, isTrue);
    expect(result!.iconUrl, isNull);
  });
  testWidgets('cancel discards edited name and URL', (tester) async {
    BrowserBookmark? result;
    await open(tester, (value) => result = value);
    await tester.enterText(field('App name'), 'Unsaved');
    await tester.enterText(field('Launch URL'), 'https://example.com/unsaved');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(original.url, contains('keep=1'));
  });
  Future<String> image(WidgetTester tester) async {
    late String value;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final raster = await picture.toImage(4, 4);
      final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
      value =
          'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}';
      raster.dispose();
      picture.dispose();
    });
    return value;
  }

  testWidgets('selected custom image saves, takes precedence and can be reset',
      (tester) async {
    BrowserBookmark? result;
    final png = await image(tester);
    await open(tester, (value) => result = value, pick: () async => png);
    await tester.tap(find.text('Choose thumbnail'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.thumbnail, png);
    await tester.pumpWidget(MaterialApp(
        home: BookmarkEditor(bookmark: result!, bookmarks: [result!])));
    await tester.tap(find.text('Use automatic icon'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });
  testWidgets('cancel discards a selected custom image', (tester) async {
    BrowserBookmark? result;
    final png = await image(tester);
    await open(tester, (value) => result = value, pick: () async => png);
    await tester.tap(find.text('Choose thumbnail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(original.customImage, isNull);
  });
  testWidgets('picker cancellation and unchanged URL preserve automatic icon',
      (tester) async {
    BrowserBookmark? result;
    await open(tester, (value) => result = value, pick: () async => null);
    await tester.tap(find.text('Choose thumbnail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.url, original.url);
    expect(result!.iconUrl, original.iconUrl);
  });
}
