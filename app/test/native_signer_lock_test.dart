import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';

void main() {
  test('native signing rejects locked identities and recovers after unlock',
      () async {
    final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
    final bridge = NativeCoreBridge();
    final config = AppConfig.defaults().copyWith(
        deviceNpub: identity.npub, devicePublicKeyHex: identity.publicKeyHex);
    for (final secret in ['', '  ', identity.nsec, '']) {
      final current = config.copyWith(deviceSecret: secret);
      final results = [
        await bridge.signEvent(
            config: current,
            event: {'kind': 1, 'content': 'fixture', 'tags': []}),
        await bridge.signNip98(
            config: current, method: 'GET', url: 'https://fixture.test'),
      ];
      for (final result in results) {
        expect(result.ok, current.hasDeviceSecret);
        if (!current.hasDeviceSecret) {
          expect(result.error, NativeCoreBridge.signerLockedError);
          expect(result.json, isEmpty);
        }
      }
    }
  });
}
