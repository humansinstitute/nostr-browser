import 'dart:convert';
import 'dart:math';

import 'package:bech32/bech32.dart';
import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';

class NostrCrypto {
  static const _secp256k1OrderHex =
      'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141';

  static NostrIdentity generateIdentity() {
    final random = Random.secure();
    while (true) {
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      final hex = _hexEncode(bytes);
      if (!_isValidSecretHex(hex)) continue;
      return importIdentity(hex);
    }
  }

  static NostrIdentity importIdentity(String secret) {
    final secretHex = _normalizeSecret(secret);
    final publicKeyHex = bip340.getPublicKey(secretHex);
    return NostrIdentity(
      nsec: _encodeBech32('nsec', _hexDecode(secretHex)),
      secretHex: secretHex,
      npub: _encodeBech32('npub', _hexDecode(publicKeyHex)),
      publicKeyHex: publicKeyHex,
    );
  }

  static String publicKeyHexFromNpub(String npub) {
    final decoded = bech32.decode(npub.trim(), 2000);
    if (decoded.hrp != 'npub') {
      throw const FormatException('expected npub public key');
    }
    final bytes = _convertBits(decoded.data, 5, 8, false);
    if (bytes.length != 32) {
      throw const FormatException('public key must be 32 bytes');
    }
    return _hexEncode(bytes);
  }

  static Map<String, dynamic> signEvent({
    required String secret,
    required Map<String, dynamic> event,
  }) {
    final identity = importIdentity(secret);
    final createdAt = _integer(event['created_at']) ?? _currentUnixTimestamp();
    final kind = _integer(event['kind']);
    if (kind == null) {
      throw const FormatException('event kind is required');
    }
    final tags = _normalizeTags(event['tags']);
    final content = event['content']?.toString() ?? '';
    final unsigned = [
      0,
      identity.publicKeyHex,
      createdAt,
      kind,
      tags,
      content,
    ];
    final id = _sha256Hex(utf8.encode(jsonEncode(unsigned)));
    final sig = bip340.sign(identity.secretHex, id, ''.padLeft(64, '0'));
    return {
      'id': id,
      'pubkey': identity.publicKeyHex,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': sig,
    };
  }

  static SignedNip98 signNip98({
    required String secret,
    required String method,
    required String url,
    String? body,
  }) {
    final normalizedMethod = method.trim().toUpperCase();
    if (normalizedMethod.isEmpty ||
        !RegExp(r'^[A-Z-]+$').hasMatch(normalizedMethod)) {
      throw FormatException('invalid method: $method');
    }
    final uri = Uri.parse(url);
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw FormatException('invalid url: $url');
    }

    final tags = <List<String>>[
      ['u', uri.toString()],
      ['method', normalizedMethod],
    ];
    if (body != null && body.isNotEmpty) {
      tags.add(['payload', _sha256Hex(utf8.encode(body))]);
    }

    final event = signEvent(
      secret: secret,
      event: {
        'kind': 27235,
        'tags': tags,
        'content': '',
      },
    );
    final authorization =
        'Nostr ${base64.encode(utf8.encode(jsonEncode(event)))}';
    return SignedNip98(authorization: authorization, event: event);
  }

  static String _normalizeSecret(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('nsec')) {
      final decoded = bech32.decode(trimmed, 2000);
      if (decoded.hrp != 'nsec') {
        throw const FormatException('expected nsec secret key');
      }
      final bytes = _convertBits(decoded.data, 5, 8, false);
      if (bytes.length != 32) {
        throw const FormatException('secret key must be 32 bytes');
      }
      final hex = _hexEncode(bytes);
      if (!_isValidSecretHex(hex)) {
        throw const FormatException('invalid secret key');
      }
      return hex;
    }
    final hex = trimmed.toLowerCase();
    if (!_isValidSecretHex(hex)) {
      throw const FormatException('secret key must be 32-byte hex or nsec');
    }
    return hex;
  }

  static bool _isValidSecretHex(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) return false;
    final secret = BigInt.parse(value, radix: 16);
    final order = BigInt.parse(_secp256k1OrderHex, radix: 16);
    return secret > BigInt.zero && secret < order;
  }

  static List<List<String>> _normalizeTags(Object? value) {
    if (value is! List) return const [];
    return [
      for (final tag in value)
        if (tag is List) [for (final item in tag) item.toString()],
    ];
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static int _currentUnixTimestamp() {
    return DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  }

  static String _sha256Hex(List<int> bytes) {
    return _hexEncode(sha256.convert(bytes).bytes);
  }

  static String _encodeBech32(String hrp, List<int> bytes) {
    return bech32.encode(Bech32(hrp, _convertBits(bytes, 8, 5, true)), 2000);
  }

  static List<int> _convertBits(
    List<int> data,
    int from,
    int to,
    bool pad,
  ) {
    var acc = 0;
    var bits = 0;
    final result = <int>[];
    final maxv = (1 << to) - 1;
    final maxAcc = (1 << (from + to - 1)) - 1;
    for (final value in data) {
      if (value < 0 || (value >> from) != 0) {
        throw const FormatException('invalid bech32 data');
      }
      acc = ((acc << from) | value) & maxAcc;
      bits += from;
      while (bits >= to) {
        bits -= to;
        result.add((acc >> bits) & maxv);
      }
    }
    if (pad) {
      if (bits > 0) {
        result.add((acc << (to - bits)) & maxv);
      }
    } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
      throw const FormatException('invalid bech32 padding');
    }
    return result;
  }

  static List<int> _hexDecode(String value) {
    if (value.length.isOdd) {
      throw const FormatException('hex length must be even');
    }
    final bytes = <int>[];
    for (var i = 0; i < value.length; i += 2) {
      bytes.add(int.parse(value.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  static String _hexEncode(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class NostrIdentity {
  const NostrIdentity({
    required this.nsec,
    required this.secretHex,
    required this.npub,
    required this.publicKeyHex,
  });

  final String nsec;
  final String secretHex;
  final String npub;
  final String publicKeyHex;
}

class SignedNip98 {
  const SignedNip98({
    required this.authorization,
    required this.event,
  });

  final String authorization;
  final Map<String, dynamic> event;
}
