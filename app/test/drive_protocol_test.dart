import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/drive/drive_protocol.dart';

void main() {
  final owner = NostrCrypto.generateIdentity(),
      member = NostrCrypto.generateIdentity();
  final now = DateTime.now();
  test('private owner on another device; others including admin fail closed',
      () {
    final policy = DrivePolicy({
      'share': {'enabled': true},
      'allowed_npubs': [owner.npub]
    }, now);
    expect(policy.allows(owner.publicKeyHex, now), isTrue);
    expect(policy.allows(member.publicKeyHex, now), isFalse);
    expect(
        policy.allows(owner.publicKeyHex, now.add(const Duration(minutes: 15))),
        isFalse);
    expect(
        policy.allows(
            owner.publicKeyHex, now.subtract(const Duration(seconds: 1))),
        isFalse);
  });
  test(
      'workspace cached membership, failed refresh never extends age, reconnect revokes and local stop blocks',
      () {
    final old = DrivePolicy({
      'share': {'enabled': true},
      'allowed_npubs': [owner.npub, member.npub]
    }, now);
    expect(
        old.allows(member.publicKeyHex, now.add(const Duration(minutes: 14))),
        isTrue);
    expect(
        old.allows(member.publicKeyHex, now.add(const Duration(minutes: 15))),
        isFalse);
    final fresh = DrivePolicy({
      'share': {'enabled': true},
      'allowed_npubs': [owner.npub]
    }, now.add(const Duration(minutes: 14)));
    expect(
        fresh.allows(member.publicKeyHex, now.add(const Duration(minutes: 14))),
        isFalse);
    expect(
        DrivePolicy({
          'share': {'enabled': false},
          'allowed_npubs': [owner.npub]
        }, now)
            .allows(owner.publicKeyHex, now),
        isFalse);
  });
  test(
      'signed request binds endpoint, workspace, share, query, method, timestamp and nonce; replay rejected',
      () {
    const url = 'http://host.fips:7345/drive/v1/share/list?path=folder';
    final event = NostrCrypto.signEvent(secret: owner.nsec, event: {
      'kind': 27235,
      'created_at': now.millisecondsSinceEpoch ~/ 1000,
      'content': '',
      'tags': [
        ['u', url],
        ['method', 'GET'],
        ['workspace', 'workspace'],
        ['share', 'share'],
        ['nonce', 'a' * 32]
      ]
    });
    final auth = 'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}';
    final verifier = DriveRequestVerifier();
    expect(verifier.verify(auth, url, 'workspace', 'share', now),
        owner.publicKeyHex);
    expect(() => verifier.verify(auth, url, 'workspace', 'share', now),
        throwsStateError);
    for (final input in [
      ['${url}x', 'workspace', 'share'],
      [url, 'other', 'share'],
      [url, 'workspace', 'other']
    ]) {
      expect(
          () => DriveRequestVerifier()
              .verify(auth, input[0], input[1], input[2], now),
          throwsStateError);
    }
    expect(
        () => DriveRequestVerifier().verify(auth, url, 'workspace', 'share',
            now.add(const Duration(seconds: 62))),
        throwsStateError);
    event['sig'] = '0' * 128;
    expect(
        () => DriveRequestVerifier().verify(
            'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}',
            url,
            'workspace',
            'share',
            now),
        throwsStateError);
  });
}
