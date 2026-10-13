import 'dart:convert';
import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import '../../core/nostr_crypto.dart';

class DrivePolicyDenied implements Exception {
  const DrivePolicyDenied({this.statusCode, this.body});

  final int? statusCode;
  final Map<String, dynamic>? body;

  String get safeMessage {
    final code = body?['code'] ?? body?['error'];
    final suffix = code is String && code.isNotEmpty ? ' $code' : '';
    return 'Tower rejected the request${statusCode == null ? '' : ' (HTTP $statusCode$suffix)'}';
  }
}

class DriveTowerException implements Exception {
  const DriveTowerException(this.statusCode, this.body, this.rawBody);

  final int statusCode;
  final Map<String, dynamic>? body;
  final String rawBody;

  String get safeMessage {
    final code = body?['code'] ?? body?['error'];
    if (code is String && code.isNotEmpty) {
      return 'Tower returned HTTP $statusCode ($code)';
    }
    return 'Tower returned HTTP $statusCode';
  }

  @override
  String toString() => safeMessage;
}

class DriveRegistrationException implements Exception {
  const DriveRegistrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DrivePolicy {
  DrivePolicy(this.value, this.fetchedAt);
  final Map<String, dynamic> value;
  final DateTime fetchedAt;
  bool allows(String publicKey, DateTime now) {
    final age = now.difference(fetchedAt);
    if (age.isNegative ||
        age >= const Duration(minutes: 15) ||
        value['share']['enabled'] != true) {
      return false;
    }
    return (value['allowed_npubs'] as List)
        .any((n) => NostrCrypto.publicKeyHexFromNpub(n as String) == publicKey);
  }
}

class DriveRequestVerifier {
  final Map<String, int> _seen = {};
  String verify(String? authorization, String url, String workspace,
      String share, DateTime now,
      {bool consume = true}) {
    try {
      if (authorization == null ||
          authorization.length > 8192 ||
          !authorization.startsWith('Nostr ')) {
        throw 0;
      }
      final e =
          jsonDecode(utf8.decode(base64Decode(authorization.substring(6))))
              as Map<String, dynamic>;
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      _seen.removeWhere((_, expiry) => expiry < seconds);
      final tags = e['tags'] as List;
      if (e['kind'] != 27235 ||
          e['content'] != '' ||
          e['created_at'] is! int ||
          (seconds - (e['created_at'] as int)).abs() > 60 ||
          tags.length != 5) {
        throw 0;
      }
      final expected = [
        ['u', url],
        ['method', 'GET'],
        ['workspace', workspace],
        ['share', share]
      ];
      for (var i = 0; i < 4; i++) {
        if (jsonEncode(tags[i]) != jsonEncode(expected[i])) throw 0;
      }
      if (tags[4] is! List ||
          tags[4].length != 2 ||
          tags[4][0] != 'nonce' ||
          !RegExp(r'^[a-zA-Z0-9_-]{32,128}$').hasMatch(tags[4][1] as String)) {
        throw 0;
      }
      final id = sha256
          .convert(utf8.encode(jsonEncode([
            0,
            e['pubkey'],
            e['created_at'],
            e['kind'],
            tags,
            e['content']
          ])))
          .toString();
      if (id != e['id'] ||
          _seen.containsKey(id) ||
          (consume && _seen.length >= 8192) ||
          !bip340.verify(e['pubkey'] as String, id, e['sig'] as String)) {
        throw 0;
      }
      if (consume) _seen[id] = (e['created_at'] as int) + 61;
      return e['pubkey'] as String;
    } catch (_) {
      throw StateError('invalid_or_replayed_request');
    }
  }
}
