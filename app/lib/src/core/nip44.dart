import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/ecc/api.dart';

import 'nostr_crypto.dart';

/// Cross-platform NIP-44 v2 implementation used for identity self-encryption.
class Nip44 {
  Nip44({List<int> Function(int length)? randomBytes})
      : _randomBytes = randomBytes ?? _secureRandomBytes;

  static const maxPlaintextBytes = 2 * 1024 * 1024;
  static final ECDomainParameters _curve = ECDomainParameters('secp256k1');
  static final BigInt _fieldPrime = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
    radix: 16,
  );
  final List<int> Function(int length) _randomBytes;

  Future<String> encrypt({
    required String secret,
    required String peerPublicKeyHex,
    required String plaintext,
    List<int>? nonce,
  }) async {
    final clear = utf8.encode(plaintext);
    if (clear.isEmpty || clear.length > maxPlaintextBytes) {
      throw const FormatException('invalid NIP-44 plaintext length');
    }
    final messageNonce = nonce ?? _randomBytes(32);
    if (messageNonce.length != 32) {
      throw const FormatException('NIP-44 nonce must be 32 bytes');
    }
    final conversation = conversationKey(
      secret: secret,
      peerPublicKeyHex: peerPublicKeyHex,
    );
    final keys = messageKeys(conversation, messageNonce);
    final padded = _pad(clear);
    final cipher = Chacha20(macAlgorithm: MacAlgorithm.empty);
    final encrypted = await cipher.encrypt(
      padded,
      secretKey: SecretKey(keys.sublist(0, 32)),
      nonce: keys.sublist(32, 44),
    );
    final mac = dart_crypto.Hmac(dart_crypto.sha256, keys.sublist(44, 76))
        .convert([...messageNonce, ...encrypted.cipherText]).bytes;
    return base64.encode([2, ...messageNonce, ...encrypted.cipherText, ...mac]);
  }

  Future<String> decrypt({
    required String secret,
    required String peerPublicKeyHex,
    required String payload,
  }) async {
    if (payload.startsWith('#')) {
      throw const FormatException('unsupported NIP-44 payload version');
    }
    if (payload.length < 132 || payload.length > 4000000) {
      throw const FormatException('invalid NIP-44 payload size');
    }
    late final List<int> decoded;
    try {
      decoded = base64.decode(payload);
    } catch (_) {
      throw const FormatException('invalid NIP-44 base64');
    }
    if (decoded.length < 99 || decoded.first != 2) {
      throw const FormatException('unsupported or invalid NIP-44 payload');
    }
    final nonce = decoded.sublist(1, 33);
    final ciphertext = decoded.sublist(33, decoded.length - 32);
    final suppliedMac = decoded.sublist(decoded.length - 32);
    final conversation = conversationKey(
      secret: secret,
      peerPublicKeyHex: peerPublicKeyHex,
    );
    final keys = messageKeys(conversation, nonce);
    final expectedMac =
        dart_crypto.Hmac(dart_crypto.sha256, keys.sublist(44, 76))
            .convert([...nonce, ...ciphertext]).bytes;
    if (!_constantTimeEqual(suppliedMac, expectedMac)) {
      throw const FormatException('NIP-44 authentication failed');
    }
    final cipher = Chacha20(macAlgorithm: MacAlgorithm.empty);
    final padded = await cipher.decrypt(
      SecretBox(ciphertext, nonce: keys.sublist(32, 44), mac: Mac.empty),
      secretKey: SecretKey(keys.sublist(0, 32)),
    );
    return utf8.decode(_unpad(padded), allowMalformed: false);
  }

  static List<int> conversationKey({
    required String secret,
    required String peerPublicKeyHex,
  }) {
    final identity = NostrCrypto.importIdentity(secret);
    final peer = peerPublicKeyHex.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(peer)) {
      throw const FormatException('invalid NIP-44 public key');
    }
    final x = BigInt.parse(peer, radix: 16);
    final point = _liftX(x);
    final shared = point * BigInt.parse(identity.secretHex, radix: 16);
    if (shared == null || shared.isInfinity) {
      throw const FormatException('invalid NIP-44 shared point');
    }
    final sharedX = _bigIntBytes(shared.x!.toBigInteger()!, 32);
    return dart_crypto.Hmac(dart_crypto.sha256, utf8.encode('nip44-v2'))
        .convert(sharedX)
        .bytes;
  }

  static List<int> messageKeys(List<int> conversationKey, List<int> nonce) {
    if (conversationKey.length != 32 || nonce.length != 32) {
      throw const FormatException('invalid NIP-44 key material');
    }
    return _hkdfExpand(conversationKey, nonce, 76);
  }

  static ECPoint _liftX(BigInt x) {
    if (x < BigInt.zero || x >= _fieldPrime) {
      throw const FormatException('invalid NIP-44 public key point');
    }
    final ySquared =
        (x.modPow(BigInt.from(3), _fieldPrime) + BigInt.from(7)) % _fieldPrime;
    var y = ySquared.modPow(
      (_fieldPrime + BigInt.one) ~/ BigInt.from(4),
      _fieldPrime,
    );
    if (y.modPow(BigInt.two, _fieldPrime) != ySquared) {
      throw const FormatException('invalid NIP-44 public key point');
    }
    if (y.isOdd) y = _fieldPrime - y;
    return _curve.curve.createPoint(x, y);
  }

  static List<int> _pad(List<int> plaintext) {
    final length = plaintext.length;
    final prefix = length < 65536
        ? [(length >> 8) & 0xff, length & 0xff]
        : [
            0,
            0,
            (length >> 24) & 0xff,
            (length >> 16) & 0xff,
            (length >> 8) & 0xff,
            length & 0xff,
          ];
    return [
      ...prefix,
      ...plaintext,
      ...List<int>.filled(_paddedLength(length) - length, 0),
    ];
  }

  static List<int> _unpad(List<int> padded) {
    if (padded.length < 34) {
      throw const FormatException('invalid NIP-44 padding');
    }
    final first = padded[0] << 8 | padded[1];
    final int length;
    final int prefixLength;
    if (first == 0) {
      if (padded.length < 6) {
        throw const FormatException('invalid NIP-44 padding');
      }
      length = padded[2] << 24 | padded[3] << 16 | padded[4] << 8 | padded[5];
      prefixLength = 6;
      if (length < 65536) throw const FormatException('invalid NIP-44 padding');
    } else {
      length = first;
      prefixLength = 2;
    }
    if (length < 1 ||
        length > maxPlaintextBytes ||
        padded.length != prefixLength + _paddedLength(length)) {
      throw const FormatException('invalid NIP-44 padding');
    }
    final suffix = padded.sublist(prefixLength + length);
    if (suffix.any((byte) => byte != 0)) {
      throw const FormatException('invalid NIP-44 padding');
    }
    return padded.sublist(prefixLength, prefixLength + length);
  }

  static int _paddedLength(int length) {
    if (length <= 32) return 32;
    var nextPower = 1;
    while (nextPower < length) {
      nextPower <<= 1;
    }
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * ((length - 1) ~/ chunk + 1);
  }

  static List<int> _hkdfExpand(List<int> key, List<int> info, int length) {
    final result = <int>[];
    var previous = <int>[];
    for (var counter = 1; result.length < length; counter++) {
      previous = dart_crypto.Hmac(dart_crypto.sha256, key)
          .convert([...previous, ...info, counter]).bytes;
      result.addAll(previous);
    }
    return result.sublist(0, length);
  }

  static bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  static List<int> _bigIntBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  static List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
