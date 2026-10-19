import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/nip44.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';

void main() {
  test('matches the published NIP-44 v2 encrypt/decrypt vector', () async {
    const secretA =
        '0000000000000000000000000000000000000000000000000000000000000001';
    const secretB =
        '0000000000000000000000000000000000000000000000000000000000000002';
    const nonce =
        '0000000000000000000000000000000000000000000000000000000000000001';
    const expected =
        'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb';
    final peer = NostrCrypto.importIdentity(secretB).publicKeyHex;
    final encrypted = await Nip44().encrypt(
      secret: secretA,
      peerPublicKeyHex: peer,
      plaintext: 'a',
      nonce: _hex(nonce),
    );
    expect(encrypted, expected);
    expect(
      await Nip44().decrypt(
        secret: secretA,
        peerPublicKeyHex: peer,
        payload: encrypted,
      ),
      'a',
    );
  });

  test('conversation key matches the official vector and tampering fails',
      () async {
    const secret =
        '315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268';
    const peer =
        'c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133';
    expect(
      _hexString(Nip44.conversationKey(secret: secret, peerPublicKeyHex: peer)),
      '3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1',
    );
    final payload = await Nip44()
        .encrypt(secret: secret, peerPublicKeyHex: peer, plaintext: 'settings');
    final bytes = base64.decode(payload)..[40] ^= 1;
    expect(
      () => Nip44().decrypt(
          secret: secret,
          peerPublicKeyHex: peer,
          payload: base64.encode(bytes)),
      throwsA(isA<FormatException>()),
    );
  });
}

List<int> _hex(String value) => [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];

String _hexString(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
