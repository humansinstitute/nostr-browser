import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_recovery.dart';

void main() {
  test(
      'workspace upload, private pointer read and fetch use exact signed routes',
      () async {
    final bytes = utf8.encode('opaque-ciphertext');
    final hash = NostrCrypto.sha256Hex(bytes);
    final seen = <String>[];
    Map<String, dynamic>? currentRow;
    final client = MockClient((request) async {
      _expectFreshHumanNip98(request);
      seen.add('${request.method} ${request.url.path}');
      final path = request.url.path;
      if (request.method == 'GET' && path == _rowsPath) {
        return _json(200, _envelope({'rows': <dynamic>[]}));
      }
      if (path == '$_workspacePath/storage/prepare') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys, {
          'content_type',
          'file_name',
          'size_bytes',
          'is_public',
          'metadata'
        });
        expect(body.containsKey('owner_npub'), isFalse);
        expect(body.containsKey('owner_group_id'), isFalse);
        expect(body.containsKey('access_group_ids'), isFalse);
        return _json(201, {'object_id': _objectId, 'owner_npub': _ownerNpub});
      }
      if (request.method == 'PUT' && path == '/api/v4/storage/$_objectId') {
        expect(base64Decode(jsonDecode(request.body)['base64_data']), bytes);
        return _json(200, {});
      }
      if (path == '/api/v4/storage/$_objectId/complete') {
        expect(jsonDecode(request.body),
            {'sha256_hex': hash, 'size_bytes': bytes.length});
        return _json(200, {});
      }
      if (request.method == 'GET' && path == '/api/v4/storage/$_objectId') {
        return _json(200, {
          'sha256_hex': hash,
          'completed_at': '2026-10-20T00:00:00Z',
          'is_public': false,
        });
      }
      if (request.method == 'POST' && path == _rowsPath) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['row_id'], 'current-v1');
        expect(body['visibility'], 'private');
        if (currentRow != null) {
          return _json(409, {'code': 'row_conflict'});
        }
        currentRow = {...body, 'owner_npub': _ownerNpub};
        return _json(201, _envelope({'row': currentRow}));
      }
      if (request.method == 'PATCH' && path == '$_rowsPath/current-v1') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        currentRow = {
          'row_id': 'current-v1',
          'owner_npub': _ownerNpub,
          'visibility': body['visibility'],
          'data': body['data'],
        };
        return _json(200, _envelope({'row': currentRow}));
      }
      if (request.method == 'GET' && path == '$_rowsPath/current-v1') {
        return _json(200, _envelope({'row': currentRow}));
      }
      if (path == '/api/v4/storage/$_objectId/content') {
        return http.Response.bytes(bytes, 200);
      }
      fail('Unexpected request: ${request.method} ${request.url}');
    });
    final adapter = TowerNStackStorageClient(client: client);
    final pointer = await adapter.upload(
      target: _target,
      secret: _secret,
      bytes: bytes,
      sha256: hash,
      snapshotRevision: 7,
      updatedAt: DateTime.utc(2026, 10, 20),
      relays: const ['wss://relay.example'],
    );
    final read = await adapter.readPointer(
      target: _target,
      secret: _secret,
      relays: const ['wss://relay.example'],
    );
    expect(read.workspaceId, _workspaceId);
    expect(read.workspaceOwnerNpub, _ownerNpub);
    await adapter.upload(
      target: _target,
      secret: _secret,
      bytes: bytes,
      sha256: hash,
      snapshotRevision: 8,
      updatedAt: DateTime.utc(2026, 10, 20, 1),
      relays: const ['wss://relay.example'],
    );
    expect(
        await adapter.fetchObject(
            target: _target, pointer: pointer, secret: _secret),
        bytes);
    expect(seen, contains('POST $_workspacePath/storage/prepare'));
    expect(seen, isNot(contains('POST /api/v4/storage/prepare')));
    expect(seen, contains('POST $_rowsPath'));
    expect(seen, contains('GET $_rowsPath/current-v1'));
    expect(seen, contains('PATCH $_rowsPath/current-v1'));
  });

  test('missing namespace is explicit and manager enablement is exact',
      () async {
    var enabled = false;
    final client = MockClient((request) async {
      _expectFreshHumanNip98(request);
      if (request.method == 'GET' && request.url.path == _rowsPath) {
        return enabled
            ? _json(200, _envelope({'rows': <dynamic>[]}))
            : _json(404, {'code': 'app_not_found'});
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/v4/workspaces/$_ownerNpub/apps') {
        expect(jsonDecode(request.body), {
          'app_npub': nbrowserAppNpub,
          'app_name': 'NBrowser',
          'enabled': true,
          'capabilities': ['storage.private', 'app_rows.private_only'],
        });
        enabled = true;
        return _json(200, {'enabled': true});
      }
      fail('Unexpected request: ${request.method} ${request.url}');
    });
    final adapter = TowerNStackStorageClient(client: client);
    expect(
      await adapter.namespaceState(target: _target, secret: _secret),
      NStackBackupNamespaceState.managerRequired,
    );
    await adapter.enableNamespace(target: _target, secret: _secret);
    expect(
      await adapter.namespaceState(target: _target, secret: _secret),
      NStackBackupNamespaceState.enabled,
    );
  });

  test('workspace response disagreement and ordinary-member enable fail closed',
      () async {
    final mismatch = TowerNStackStorageClient(
      client: MockClient((request) async {
        _expectFreshHumanNip98(request);
        return _json(200, {
          'workspace_id': _workspaceId,
          'workspace_owner_npub': nbrowserAppNpub,
          'rows': <dynamic>[],
        });
      }),
    );
    await expectLater(
      mismatch.namespaceState(target: _target, secret: _secret),
      throwsA(isA<NStackStorageException>()
          .having((error) => error.code, 'code', 'workspace_mismatch')),
    );
    await expectLater(
      mismatch.enableNamespace(
        target: const NStackBackupTarget(
          hostUrl: 'https://host.example',
          workspaceId: _workspaceId,
          workspaceOwnerNpub: _ownerNpub,
          identityNpub: _ownerNpub,
          canManageNamespace: false,
        ),
        secret: _secret,
      ),
      throwsA(isA<NStackStorageException>()
          .having((error) => error.code, 'code', 'workspace_manager_required')),
    );
  });
}

void _expectFreshHumanNip98(http.Request request) {
  final authorization = request.headers['authorization'];
  expect(authorization, startsWith('Nostr '));
  final event =
      jsonDecode(utf8.decode(base64Decode(authorization!.substring(6))))
          as Map<String, dynamic>;
  expect(NostrCrypto.verifyEvent(event), isTrue);
  expect(event['pubkey'], NostrCrypto.importIdentity(_secret).publicKeyHex);
  final tags = (event['tags'] as List).cast<List>();
  expect(
      tags.any((tag) =>
          tag.length == 2 && tag[0] == 'u' && tag[1] == request.url.toString()),
      isTrue);
  expect(
      tags.any((tag) =>
          tag.length == 2 && tag[0] == 'method' && tag[1] == request.method),
      isTrue);
  if (request.body.isNotEmpty) {
    expect(
        tags.any((tag) =>
            tag.length == 2 &&
            tag[0] == 'payload' &&
            tag[1] == NostrCrypto.sha256Hex(request.bodyBytes)),
        isTrue);
  } else {
    expect(
        tags.where((tag) => tag.isNotEmpty && tag.first == 'payload'), isEmpty);
  }
}

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _envelope(Map<String, dynamic> body) => {
      'workspace_id': _workspaceId,
      'workspace_owner_npub': _ownerNpub,
      ...body,
    };

const _secret =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _workspaceId = '11111111-1111-4111-8111-111111111111';
const _objectId = '22222222-2222-4222-8222-222222222222';
const _ownerNpub =
    'npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d';
const _workspacePath = '/api/v4/flightdeck-pg/workspaces/$_workspaceId';
const _rowsPath =
    '$_workspacePath/apps/$nbrowserAppNpub/db/settings-backups/rows';
const _target = NStackBackupTarget(
  hostUrl: 'https://host.example',
  workspaceId: _workspaceId,
  workspaceOwnerNpub: _ownerNpub,
  identityNpub: _ownerNpub,
  canManageNamespace: true,
);
