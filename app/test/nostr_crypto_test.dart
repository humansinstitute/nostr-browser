import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';

void main() {
  const secret =
      '0000000000000000000000000000000000000000000000000000000000000001';

  test('imports hex secrets and exports nsec/npub identity', () {
    final identity = NostrCrypto.importIdentity(secret);

    expect(identity.secretHex, secret);
    expect(identity.publicKeyHex,
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798');
    expect(identity.nsec, startsWith('nsec1'));
    expect(identity.npub, startsWith('npub1'));
    expect(
        NostrCrypto.publicKeyHexFromNpub(identity.npub), identity.publicKeyHex);

    final roundTrip = NostrCrypto.importIdentity(identity.nsec);
    expect(roundTrip.secretHex, secret);
    expect(roundTrip.publicKeyHex, identity.publicKeyHex);
  });

  test('signs NIP-07 event templates', () {
    final signed = NostrCrypto.signEvent(
      secret: secret,
      event: {
        'kind': 1,
        'tags': [
          ['client', 'wingman'],
        ],
        'content': 'hello',
        'created_at': 1700000000,
      },
    );

    expect(signed['kind'], 1);
    expect(signed['content'], 'hello');
    expect(
      bip340.verify(
        signed['pubkey'] as String,
        signed['id'] as String,
        signed['sig'] as String,
      ),
      isTrue,
    );
  });

  test('signs NIP-98 authorization events', () {
    final signed = NostrCrypto.signNip98(
      secret: secret,
      method: 'post',
      url: 'https://tower.example/api',
      body: '{"hello":"wingman"}',
    );

    expect(signed.authorization, startsWith('Nostr '));
    final encoded = signed.authorization.substring('Nostr '.length);
    final event =
        jsonDecode(utf8.decode(base64.decode(encoded))) as Map<String, dynamic>;

    expect(event['kind'], 27235);
    final tags = (event['tags'] as List<dynamic>).cast<List<dynamic>>();
    expect(
      tags.any(
          (tag) => tag.length == 2 && tag[0] == 'method' && tag[1] == 'POST'),
      isTrue,
    );
    expect(
      bip340.verify(
        event['pubkey'] as String,
        event['id'] as String,
        event['sig'] as String,
      ),
      isTrue,
    );
  });
}
