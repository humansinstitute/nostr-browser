import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/nstack/nstack_recovery.dart';

void main() {
  test(
      'Tower adapter freshly signs exact upload/fetch requests and checks hash',
      () async {
    const secret =
        '0000000000000000000000000000000000000000000000000000000000000001';
    final identity = NostrCrypto.importIdentity(secret);
    final bytes = utf8.encode('opaque-ciphertext');
    final hash = NostrCrypto.sha256Hex(bytes);
    final seen = <String>[];
    final client = MockClient((request) async {
      final authorization = request.headers['authorization'];
      expect(authorization, startsWith('Nostr '));
      final event =
          jsonDecode(utf8.decode(base64Decode(authorization!.substring(6))))
              as Map<String, dynamic>;
      expect(NostrCrypto.verifyEvent(event), isTrue);
      final tags = (event['tags'] as List).cast<List>();
      expect(
          tags.any((tag) =>
              tag.length == 2 &&
              tag[0] == 'u' &&
              tag[1] == request.url.toString()),
          isTrue);
      expect(
          tags.any((tag) =>
              tag.length == 2 &&
              tag[0] == 'method' &&
              tag[1] == request.method),
          isTrue);
      seen.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/v4/storage/prepare') {
        return http.Response(
            jsonEncode({'object_id': '11111111-1111-4111-8111-111111111111'}),
            200);
      }
      if (request.method == 'PUT') return http.Response('{}', 200);
      if (request.url.path.endsWith('/complete')) {
        expect(jsonDecode(request.body)['sha256_hex'], hash);
        return http.Response('{}', 200);
      }
      if (request.url.path.endsWith('/content')) {
        return http.Response.bytes(bytes, 200);
      }
      return http.Response(
          jsonEncode({
            'sha256_hex': hash,
            'completed_at': '2026-10-19T00:00:00Z',
            'is_public': false,
          }),
          200);
    });
    final adapter = TowerNStackStorageClient(client: client);
    final objectId = await adapter.upload(
      hostUrl: 'https://host.example',
      ownerNpub: identity.npub,
      secret: secret,
      bytes: bytes,
      sha256: hash,
    );
    expect(
      await adapter.fetch(
        hostUrl: 'https://host.example',
        objectId: objectId,
        secret: secret,
        expectedSha256: hash,
      ),
      bytes,
    );
    expect(seen, [
      'POST /api/v4/storage/prepare',
      'PUT /api/v4/storage/$objectId',
      'POST /api/v4/storage/$objectId/complete',
      'GET /api/v4/storage/$objectId',
      'GET /api/v4/storage/$objectId/content',
    ]);
  });
}
