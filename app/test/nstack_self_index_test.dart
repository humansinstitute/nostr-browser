import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wingman_app/src/core/nip44.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/nstack/nstack_self_index.dart';
import 'package:wingman_app/src/features/nstack/nstack_workspace_discovery.dart';

const secret =
    '0000000000000000000000000000000000000000000000000000000000000001';
const secondSecret =
    '0000000000000000000000000000000000000000000000000000000000000002';
final user = NostrCrypto.importIdentity(secret);
final app = NostrCrypto.importIdentity(secondSecret);
const workspaceId = '11111111-2222-4333-8444-555555555555';
Map<String, String> identity([String id = workspaceId]) => {
      'workspace_id': id,
      'tower_service_npub': app.npub,
      'workspace_service_npub': app.npub,
      'workspace_owner_npub': user.npub,
      'app_npub': app.npub
    };
Future<Map<String, dynamic>> index(
    {String origin = 'https://one.test',
    int at = 100,
    bool deleted = false,
    bool nested = false,
    String id = workspaceId,
    List<List<String>>? tags}) async {
  final d =
      'fd-self:${NostrCrypto.sha256Hex(utf8.encode('v1:${user.publicKeyHex}:${app.publicKeyHex}:${app.npub}:$id'))}';
  return NostrCrypto.signEvent(secret: secret, event: {
    'kind': 33356,
    'created_at': at,
    'tags': tags ??
        [
          ['d', d],
          ['p', user.publicKeyHex],
          ['app_pub', app.publicKeyHex],
          ['protocol', 'workspace-self-index'],
          ['v', '1']
        ],
    'content': await Nip44().encrypt(
        secret: secret,
        peerPublicKeyHex: user.publicKeyHex,
        plaintext: jsonEncode({
          'type': 'flightdeck_workspace_self_index',
          'version': 1,
          'user_npub': user.npub,
          'app': {
            'app_npub': app.npub,
            'app_pubkey': app.publicKeyHex,
            'namespace': 'flightdeck_pg'
          },
          'workspace': {
            'type': 'wingman_workspace_locator',
            'version': 1,
            'tower_base_url': origin,
            'label': 'Workspace',
            if (nested) 'identity': identity(id) else ...identity(id)
          },
          'state': {'deleted': deleted},
        }))
  });
}

void main() {
  test('newer signed malformed tags shadow older usable locator', () async {
    final old = await index();
    final tags =
        (old['tags'] as List).map((t) => List<String>.from(t as List)).toList();
    final duplicateP = await index(at: 101, tags: [
      ...tags,
      ['p', user.publicKeyHex]
    ]);
    final wrongProtocol = await index(
        at: 101,
        tags: tags
            .map((t) => t[0] == 'protocol' ? ['protocol', 'unknown'] : t)
            .toList());
    final duplicateD = await index(at: 101, tags: [...tags, tags[0]]);
    expect(await workspaceIndexCandidates([old, duplicateP], secret: secret),
        isEmpty);
    expect(await workspaceIndexCandidates([old, wrongProtocol], secret: secret),
        isEmpty);
    expect(await workspaceIndexCandidates([old, duplicateD], secret: secret),
        isEmpty);
  });

  test(
      'announcement requires ACK and exact signed readback and preserves locator identity',
      () async {
    Map<String, dynamic>? published;
    final discovery = NStackSelfIndexDiscovery(
      client: MockClient((request) async =>
          http.Response(jsonEncode({'identity': identity()}), 200)),
      publish: (relay, event) async {
        published = event;
        expect(NostrCrypto.verifyEvent(event), isTrue);
        return true;
      },
      query: (relay, filter) async {
        expect(filter['ids'], [published!['id']]);
        return [published!];
      },
    );
    await discovery.announce(
        NStackIndexLocator('https://one.test', identity(), 'Workspace'),
        secret: secret);
    expect(
        (await workspaceIndexCandidates([published!], secret: secret))
            .single
            .identity,
        identity());
    final absent = NStackSelfIndexDiscovery(
      client: MockClient((request) async =>
          http.Response(jsonEncode({'identity': identity()}), 200)),
      publish: (relay, event) async => true,
      query: (relay, filter) async => [],
    );
    await expectLater(
        absent.announce(
            NStackIndexLocator('https://one.test', identity(), 'Workspace'),
            secret: secret),
        throwsStateError);
  });

  test(
      'shared nostr-tools fixture decrypts and resolves tombstones across languages',
      () async {
    final fixture = jsonDecode(
        File('test/fixtures/workspace-self-index-v1.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final events = (fixture['events'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    expect(
        (await workspaceIndexCandidates(events.take(2).toList(),
                secret: secret))
            .map((w) => w.origin)
            .toSet(),
        {'https://one.example', 'https://two.example'});
    expect(
        (await workspaceIndexCandidates(events, secret: secret))
            .map((w) => w.origin)
            .toList(),
        ['https://two.example']);
  });
  test(
      'accepts flat and nested cross-app locators, ignores other account and invalid indexes',
      () async {
    final events = [
      await index(),
      await index(
          origin: 'https://two.test',
          nested: true,
          id: '22222222-2222-4333-8444-555555555555')
    ];
    expect(
        (await workspaceIndexCandidates(events, secret: secret))
            .map((w) => w.origin)
            .toSet(),
        {'https://one.test', 'https://two.test'});
    expect(
        await workspaceIndexCandidates(events, secret: secondSecret), isEmpty);
    expect(
        await workspaceIndexCandidates([await index(origin: 'http://one.test')],
            secret: secret),
        isEmpty);
  });
  test(
      'latest signed tombstone suppresses older locator; bad signature does not',
      () async {
    final old = await index();
    final deleted = await index(at: 101, deleted: true);
    expect(await workspaceIndexCandidates([old, deleted], secret: secret),
        isEmpty);
    expect(
        await workspaceIndexCandidates([
          old,
          {...deleted, 'sig': '0' * 128}
        ], secret: secret),
        hasLength(1));
    expect(
        await workspaceIndexCandidates([old, await index(at: 1000)],
            secret: secret, now: 100),
        hasLength(1));
    final tags = (old['tags'] as List)
        .map((t) => List<String>.from(t as List))
        .toList()
      ..add(['p', user.publicKeyHex]);
    expect(
        await workspaceIndexCandidates([await index(tags: tags)],
            secret: secret),
        isEmpty);
  });
  test(
      'queries without app filter and isolates stale/revoked candidates after exact authenticated /me',
      () async {
    final events = [
      await index(),
      await index(
          origin: 'https://two.test',
          id: '22222222-2222-4333-8444-555555555555'),
      await index(
          origin: 'https://revoked.test',
          id: '33333333-2222-4333-8444-555555555555')
    ];
    final urls = <Uri>[];
    final discovery = NStackSelfIndexDiscovery(query: (relay, filter) async {
      expect(filter.containsKey('#app_pub'), isFalse);
      expect(filter['#p'], [user.publicKeyHex]);
      return events;
    }, client: MockClient((request) async {
      urls.add(request.url);
      final auth = jsonDecode(utf8.decode(
              base64Decode(request.headers['authorization']!.substring(6))))
          as Map<String, dynamic>;
      expect(NostrCrypto.verifyEvent(auth), isTrue);
      expect(request.headers['x-flightdeck-pg-app-npub'], app.npub);
      if (request.url.host == 'revoked.test') {
        return http.Response('{}', 403);
      }
      final id = request.url.path.split('/')[5];
      return http.Response(jsonEncode({'identity': identity(id)}), 200);
    }));
    final towers =
        await discovery.discover(identityNpub: user.npub, secret: secret);
    expect(towers.map((t) => t.origin).toList(),
        ['https://one.test', 'https://two.test']);
    expect(urls, hasLength(3));
  });
  test(
      'selected Tower PG pages verify membership, omit revoked rows, tolerate absent legacy endpoint',
      () async {
    final urls = <Uri>[];
    final discovery = TowerNStackWorkspaceDiscovery(
        verifyMembership: true,
        client: MockClient((request) async {
          urls.add(request.url);
          if (request.url.path == '/api/v4/workspaces') {
            return http.Response('{}', 404);
          }
          if (request.url.path.endsWith('/me')) {
            final id = request.url.path.split('/')[5];
            return http.Response(jsonEncode({'identity': identity(id)}),
                id == workspaceId ? 200 : 403);
          }
          final first = !request.url.queryParameters.containsKey('cursor');
          final id =
              first ? workspaceId : '22222222-2222-4333-8444-555555555555';
          return http.Response(
              jsonEncode({
                'workspaces': [
                  {
                    'identity': identity(id),
                    'label': 'Workspace',
                    'tower_base_url': 'https://selected.test',
                    'membership': {'role': 'member'}
                  }
                ],
                'next_cursor': first ? 'next&?' : null
              }),
              200);
        }));
    final found = await discovery.discover(
        address: 'https://selected.test',
        identityNpub: user.npub,
        secret: secret);
    expect(found.map((w) => w.remoteId).toList(), [workspaceId]);
    expect(urls.every((u) => u.host == 'selected.test'), isTrue);
    expect(
        urls
            .where((u) => u.queryParameters.containsKey('cursor'))
            .single
            .queryParameters['cursor'],
        'next&?');
  });
}
