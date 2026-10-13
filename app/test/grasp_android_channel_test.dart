import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/grasp_android_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wingman/grasp_android');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> deliver(int id, String name, String message) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('message', {
        'webViewIdentifier': id,
        'channel': name,
        'message': message,
      })),
      (_) {},
    );
  }

  tearDown(() async {
    await GraspAndroidChannel.remove(10);
    await GraspAndroidChannel.remove(20);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('dispatches only to installed native view and drops removed views',
      () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => call.method == 'install' ? true : null);
    final received = <String>[];
    expect(
        await GraspAndroidChannel.install(
            webViewIdentifier: 10,
            onMessage: (name, message) => received.add('$name:$message')),
        isTrue);
    await deliver(20, 'WingmanGrasp', 'foreign');
    await deliver(10, 'WingmanSigner', 'verified');
    await GraspAndroidChannel.remove(10);
    await deliver(10, 'WingmanGrasp', 'late');
    expect(received, ['WingmanSigner:verified']);
  });

  test('unsupported native feature drops messages and returns false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    final received = <String>[];
    expect(
        await GraspAndroidChannel.install(
            webViewIdentifier: 10,
            onMessage: (_, message) => received.add(message)),
        isFalse);
    await deliver(10, 'WingmanGrasp', 'unavailable');
    expect(received, isEmpty);
  });

  test('missing native plugin fails closed', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(
        await GraspAndroidChannel.install(
            webViewIdentifier: 20,
            onMessage: (_, __) => fail('unexpected dispatch')),
        isFalse);
  });
}
