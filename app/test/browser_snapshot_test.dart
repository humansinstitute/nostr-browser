import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/browser_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wingman/browser_snapshot');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('requests a bounded native snapshot and returns its bytes', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return Uint8List.fromList([1, 2, 3]);
    });

    expect(await BrowserSnapshot.capture(42), Uint8List.fromList([1, 2, 3]));
    expect(received?.method, 'capture');
    expect(received?.arguments, {
      'webViewIdentifier': 42,
      'width': 480,
    });
  });

  test('missing, failed, empty, and oversized snapshots use the fallback',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    expect(await BrowserSnapshot.capture(1), isNull);

    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'capture_failed'),
    );
    expect(await BrowserSnapshot.capture(1), isNull);

    messenger.setMockMethodCallHandler(channel, (_) async => Uint8List(0));
    expect(await BrowserSnapshot.capture(1), isNull);

    messenger.setMockMethodCallHandler(
      channel,
      (_) async => Uint8List(4 * 1024 * 1024 + 1),
    );
    expect(await BrowserSnapshot.capture(1), isNull);
  });
}
