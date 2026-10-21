import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/nstack/nstack_workspace_discovery.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';

void main() {
  const secret =
      '0000000000000000000000000000000000000000000000000000000000000001';
  final identity = NostrCrypto.importIdentity(secret);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
      'merges legacy and Flight Deck owner/member workspaces with exact NIP-98 bindings',
      () async {
    final other = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final event = _authorizationEvent(request);
      expect(NostrCrypto.verifyEvent(event), isTrue);
      expect(event['pubkey'], identity.publicKeyHex);
      expect(_tag(event, 'u'), request.url.toString());
      expect(_tag(event, 'method'), 'GET');
      expect(request.headers['authorization'], isNot(contains(secret)));
      if (request.url.path == '/base/api/v4/workspaces') {
        expect(request.url.toString(),
            'https://stack.example/base/api/v4/workspaces?member_npub=${Uri.encodeQueryComponent(identity.npub)}');
        return http.Response(
            jsonEncode({
              'workspaces': [
                _workspace('legacy-only', 'Legacy only', other.npub, extra: {
                  'creator_npub': identity.npub,
                  'wrapped_workspace_nsec': 'must-not-persist',
                }),
                _workspace('legacy-linked', 'Legacy linked', other.npub,
                    extra: {
                      'creator_npub': identity.npub,
                      'wrapped_workspace_nsec': 'must-not-persist',
                    }),
              ],
            }),
            200);
      }
      expect(request.url.toString(),
          'https://stack.example/base/api/v4/flightdeck-pg/workspaces?limit=200');
      return http.Response(
          jsonEncode({
            'workspaces': [
              _flightDeckWorkspace(
                'pg-linked',
                'Linked PG workspace',
                owner: identity.npub,
                workspaceService: other.npub,
                towerService: other.npub,
                role: 'owner',
                v4WorkspaceId: 'legacy-linked',
              ),
              _flightDeckWorkspace(
                'workspace-member',
                'Member workspace',
                owner: other.npub,
                workspaceService: identity.npub,
                towerService: other.npub,
                role: 'member',
                extra: const {'wrapped_secret': 'must-not-persist'},
              ),
            ],
            'next_cursor': null,
          }),
          200);
    });
    final discovery = TowerNStackWorkspaceDiscovery(client: client);
    final result = await discovery.discover(
      address: 'https://STACK.example/base/',
      identityNpub: identity.npub,
      secret: secret,
    );
    expect(result.map((workspace) => workspace.name),
        ['Legacy only', 'Linked PG workspace', 'Member workspace']);
    expect(result.first.workspaceOwnerNpub, identity.npub,
        reason: 'legacy creator_npub is the human workspace owner');
    expect(result.first.workspaceServiceNpub, other.npub);
    expect(result[1].remoteId, 'pg-linked',
        reason: 'the PG descriptor is canonical for an explicitly linked row');
    expect(result[1].stableRemoteId, 'legacy-linked');
    expect(result[1].workspaceOwnerNpub, identity.npub);
    expect(result[2].remoteId, 'workspace-member');
    expect(result.map((item) => item.toJson()).toString(),
        isNot(contains('wrapped')));
    expect(requests, hasLength(2));
    expect(
      _authorizationEvent(requests[0])['id'],
      isNot(_authorizationEvent(requests[1])['id']),
      reason: 'each exact URL receives a fresh URL-bound NIP-98 event',
    );
  });

  test(
      'binds proxy-downgraded Flight Deck summaries to the verified HTTPS root',
      () async {
    final workspaceService = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final towerService = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000003');
    final client = MockClient((request) async {
      if (request.url.path == '/base/api/v4/workspaces') {
        return http.Response(jsonEncode({'workspaces': []}), 200);
      }
      expect(request.url.toString(),
          'https://stack.example/base/api/v4/flightdeck-pg/workspaces?limit=200');
      return http.Response(
          jsonEncode({
            'identity': {
              'tower_service_npub': null,
              'workspace_service_npub': null,
              'workspace_owner_npub': null,
              'workspace_id': null,
              'app_npub': towerService.npub,
            },
            'workspaces': [
              _flightDeckWorkspace(
                'workspace-owner',
                'Owner workspace',
                owner: identity.npub,
                workspaceService: workspaceService.npub,
                towerService: towerService.npub,
                role: 'owner',
                extra: const {
                  'tower_base_url': 'http://stack.example',
                },
              ),
              _flightDeckWorkspace(
                'workspace-member',
                'Member workspace',
                owner: towerService.npub,
                workspaceService: workspaceService.npub,
                towerService: towerService.npub,
                role: 'member',
                extra: const {
                  'tower_base_url': 'http://stack.example',
                },
              ),
            ],
            'next_cursor': null,
          }),
          200);
    });

    final result = await TowerNStackWorkspaceDiscovery(client: client).discover(
      address: 'https://stack.example/base/',
      identityNpub: identity.npub,
      secret: secret,
    );

    expect(result.map((workspace) => workspace.remoteId),
        ['workspace-owner', 'workspace-member']);
    expect(result.map((workspace) => workspace.directHttpsUrl).toSet(),
        {'https://stack.example/base'});
  });

  for (final reportedTowerUrl in [
    'http://other.example',
    'http://stack.example:8080',
    'http://stack.example/other',
  ]) {
    test('rejects proxy-reported Tower mismatch $reportedTowerUrl', () async {
      final other = NostrCrypto.importIdentity(
          '0000000000000000000000000000000000000000000000000000000000000002');
      final discovery = TowerNStackWorkspaceDiscovery(
        client: MockClient((request) async {
          if (request.url.path == '/base/api/v4/workspaces') {
            return http.Response(jsonEncode({'workspaces': []}), 200);
          }
          return http.Response(
              jsonEncode({
                'workspaces': [
                  _flightDeckWorkspace(
                    'workspace-a',
                    'Workspace A',
                    owner: identity.npub,
                    workspaceService: other.npub,
                    towerService: other.npub,
                    role: 'owner',
                    extra: {'tower_base_url': reportedTowerUrl},
                  ),
                ],
                'next_cursor': null,
              }),
              200);
        }),
      );

      await expectLater(
        discovery.discover(
          address: 'https://stack.example/base',
          identityNpub: identity.npub,
          secret: secret,
        ),
        throwsA(isA<NStackWorkspaceDiscoveryException>()
            .having((error) => error.code, 'code', 'invalid_response')),
      );
    });
  }

  test('omits an unusable Flight Deck summary without hiding usable siblings',
      () async {
    final other = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient((request) async {
        if (request.url.path == '/api/v4/workspaces') {
          return http.Response(jsonEncode({'workspaces': []}), 200);
        }
        return http.Response(
            jsonEncode({
              'workspaces': [
                _flightDeckWorkspace(
                  'workspace-usable',
                  'Usable',
                  owner: identity.npub,
                  workspaceService: other.npub,
                  towerService: other.npub,
                  role: 'owner',
                  extra: const {'tower_base_url': 'http://stack.example'},
                ),
                _flightDeckWorkspace(
                  'workspace-unusable',
                  'Historical incomplete row',
                  owner: identity.npub,
                  workspaceService: other.npub,
                  towerService: other.npub,
                  role: 'member',
                  extra: const {
                    'tower_base_url': 'http://stack.example',
                    'identity': {
                      'workspace_id': 'workspace-unusable',
                      'workspace_owner_npub': null,
                      'workspace_service_npub': null,
                      'tower_service_npub': null,
                    },
                  },
                ),
              ],
              'next_cursor': null,
            }),
            200);
      }),
    );

    final result = await discovery.discover(
      address: 'https://stack.example',
      identityNpub: identity.npub,
      secret: secret,
    );

    expect(result.map((workspace) => workspace.remoteId), ['workspace-usable']);
  });

  test('duplicate Flight Deck identities remain fatal', () async {
    final other = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient((request) async {
        if (request.url.path == '/api/v4/workspaces') {
          return http.Response(jsonEncode({'workspaces': []}), 200);
        }
        final duplicate = _flightDeckWorkspace(
          'workspace-duplicate',
          'Duplicate',
          owner: identity.npub,
          workspaceService: other.npub,
          towerService: other.npub,
          role: 'owner',
        );
        return http.Response(
            jsonEncode({
              'workspaces': [duplicate, duplicate],
              'next_cursor': null,
            }),
            200);
      }),
    );

    await expectLater(
      discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      ),
      throwsA(isA<NStackWorkspaceDiscoveryException>()
          .having((error) => error.code, 'code', 'invalid_response')),
    );
  });

  test('follows bounded opaque Flight Deck cursors and signs every exact page',
      () async {
    final other = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final event = _authorizationEvent(request);
      expect(event['pubkey'], identity.publicKeyHex);
      expect(_tag(event, 'u'), request.url.toString());
      expect(_tag(event, 'method'), 'GET');
      if (request.url.path == '/api/v4/workspaces') {
        return http.Response(jsonEncode({'workspaces': []}), 200);
      }
      final cursor = request.url.queryParameters['cursor'];
      if (cursor == null) {
        return http.Response(
            jsonEncode({
              'workspaces': [
                _flightDeckWorkspace('pg-a', 'Alpha',
                    owner: identity.npub,
                    workspaceService: other.npub,
                    towerService: other.npub,
                    role: 'owner'),
              ],
              'next_cursor': 'opaque+/cursor==',
            }),
            200);
      }
      expect(cursor, 'opaque+/cursor==');
      expect(request.url.toString(),
          'https://stack.example/api/v4/flightdeck-pg/workspaces?limit=200&cursor=opaque%2B%2Fcursor%3D%3D');
      return http.Response(
          jsonEncode({
            'workspaces': [
              _flightDeckWorkspace('pg-b', 'Beta',
                  owner: identity.npub,
                  workspaceService: other.npub,
                  towerService: other.npub,
                  role: 'member'),
            ],
            'next_cursor': null,
          }),
          200);
    });

    final result = await TowerNStackWorkspaceDiscovery(client: client).discover(
      address: 'https://stack.example',
      identityNpub: identity.npub,
      secret: secret,
    );

    expect(result.map((workspace) => workspace.remoteId), ['pg-a', 'pg-b']);
    expect(requests, hasLength(3));
    expect(
        requests.map((request) => _authorizationEvent(request)['id']).toSet(),
        hasLength(3));
  });

  test('rejects repeated Flight Deck cursors without requesting forever',
      () async {
    var calls = 0;
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient((request) async {
        calls++;
        if (request.url.path == '/api/v4/workspaces') {
          return http.Response(jsonEncode({'workspaces': []}), 200);
        }
        return http.Response(
            jsonEncode({'workspaces': [], 'next_cursor': 'same-cursor'}), 200);
      }),
    );

    await expectLater(
      discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      ),
      throwsA(isA<NStackWorkspaceDiscoveryException>()
          .having((error) => error.code, 'code', 'invalid_response')),
    );
    expect(calls, 3);
  });

  test('enforces a total Flight Deck workspace limit across valid pages',
      () async {
    var page = 0;
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient((request) async {
        if (request.url.path == '/api/v4/workspaces') {
          return http.Response(jsonEncode({'workspaces': []}), 200);
        }
        final currentPage = page++;
        return http.Response(
            jsonEncode({
              'workspaces': [
                for (var index = 0;
                    index < nstackFlightDeckWorkspacePageSize;
                    index++)
                  _flightDeckWorkspace(
                      'pg-$currentPage-$index', 'Workspace $currentPage-$index',
                      owner: identity.npub,
                      workspaceService: identity.npub,
                      towerService: identity.npub,
                      role: 'member'),
              ],
              'next_cursor': 'page-${currentPage + 1}',
            }),
            200);
      }),
    );

    await expectLater(
      discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      ),
      throwsA(isA<NStackWorkspaceDiscoveryException>()
          .having((error) => error.code, 'code', 'invalid_response')),
    );
    expect(page, 5,
        reason: 'the client must stop at the 1000-workspace total limit');
  });

  for (final status in [404, 405, 501]) {
    test(
        'keeps a valid legacy result when Flight Deck discovery returns $status',
        () async {
      final discovery = TowerNStackWorkspaceDiscovery(
        client: MockClient((request) async {
          if (request.url.path == '/api/v4/workspaces') {
            return http.Response(
                jsonEncode({
                  'workspaces': [
                    _workspace('legacy-a', 'Legacy', identity.npub,
                        extra: {'creator_npub': identity.npub}),
                  ],
                }),
                200);
          }
          return http.Response('unsupported', status);
        }),
      );

      final result = await discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      );
      expect(result.single.remoteId, 'legacy-a');
    });
  }

  test('does not treat a paginated Flight Deck 404 as unsupported', () async {
    var pgPage = 0;
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient((request) async {
        if (request.url.path == '/api/v4/workspaces') {
          return http.Response(jsonEncode({'workspaces': []}), 200);
        }
        if (pgPage++ == 0) {
          return http.Response(
              jsonEncode({'workspaces': [], 'next_cursor': 'next'}), 200);
        }
        return http.Response('missing page', 404);
      }),
    );

    await expectLater(
      discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      ),
      throwsA(isA<NStackWorkspaceDiscoveryException>()
          .having((error) => error.code, 'code', 'http_error')),
    );
  });

  for (final status in [401, 403, 503]) {
    test('surfaces Flight Deck HTTP $status instead of hiding partial results',
        () async {
      final discovery = TowerNStackWorkspaceDiscovery(
        client: MockClient((request) async {
          if (request.url.path == '/api/v4/workspaces') {
            return http.Response(
                jsonEncode({
                  'workspaces': [
                    _workspace('legacy-a', 'Legacy', identity.npub,
                        extra: {'creator_npub': identity.npub}),
                  ],
                }),
                200);
          }
          return http.Response('failure', status);
        }),
      );

      await expectLater(
        discovery.discover(
          address: 'https://stack.example',
          identityNpub: identity.npub,
          secret: secret,
        ),
        throwsA(isA<NStackWorkspaceDiscoveryException>()
            .having((error) => error.code, 'code', 'http_error')),
      );
    });
  }

  test('accepts an authenticated empty workspace list', () async {
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient(
          (_) async => http.Response(jsonEncode({'workspaces': []}), 200)),
    );
    expect(
      await discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      ),
      isEmpty,
    );
  });

  test('invalid response and active identity mismatch fail closed', () async {
    var calls = 0;
    final discovery = TowerNStackWorkspaceDiscovery(
      client: MockClient((_) async {
        calls++;
        return http.Response(
            jsonEncode({
              'workspaces': [
                {'workspace_id': 'workspace-a', 'name': 'Incomplete'}
              ],
            }),
            200);
      }),
    );
    await expectLater(
      discovery.discover(
        address: 'https://stack.example',
        identityNpub: identity.npub,
        secret: secret,
      ),
      throwsA(isA<NStackWorkspaceDiscoveryException>()
          .having((error) => error.code, 'code', 'invalid_response')),
    );
    await expectLater(
      discovery.discover(
        address: 'https://stack.example',
        identityNpub: NostrCrypto.importIdentity(
                '0000000000000000000000000000000000000000000000000000000000000003')
            .npub,
        secret: secret,
      ),
      throwsA(isA<NStackWorkspaceDiscoveryException>()
          .having((error) => error.code, 'code', 'identity_changed')),
    );
    expect(calls, 1, reason: 'identity mismatch must fail before networking');
  });

  test(
      'first failure saves nothing; refresh preserves last-known-good as stale',
      () async {
    final store = NStackRegistryStore();
    final fake = _SequenceDiscovery([
      const NStackWorkspaceDiscoveryException('network_error', 'offline'),
      [_discovered('workspace-a', 'Alpha', identity.npub)],
      const NStackWorkspaceDiscoveryException('timeout', 'too slow'),
    ]);
    final service = NStackWorkspaceDiscoveryService(
      registryStore: store,
      discovery: fake,
      clock: () => DateTime.utc(2026, 10, 19, 12),
    );
    await expectLater(
      service.add(
          identityNpub: identity.npub,
          secret: secret,
          address: 'https://stack.example'),
      throwsA(isA<NStackWorkspaceDiscoveryException>()),
    );
    expect((await store.load(identity.npub)).stacks, isEmpty);

    final added = await service.add(
        identityNpub: identity.npub,
        secret: secret,
        address: 'https://stack.example');
    await expectLater(
      service.refresh(
          identityNpub: identity.npub, secret: secret, stackId: added.id),
      throwsA(isA<NStackWorkspaceDiscoveryException>()),
    );
    final stale = (await store.load(identity.npub)).stacks.single;
    expect(stale.workspaces.single.remoteId, 'workspace-a');
    expect(stale.workspaceDiscovery?.stale, isTrue);
    expect(stale.workspaceDiscovery?.errorCode, 'timeout');
  });

  test('refresh merges stable aliases, removes lost access, and keeps settings',
      () async {
    final store = NStackRegistryStore();
    await store.addOrUpdate(
      identity.npub,
      const NStackEntry(
        id: 'stack-internal',
        name: 'Manual label',
        url: 'https://stack.example',
        workspaces: [
          NStackWorkspace(
              id: 'legacy-alias',
              name: 'Typed by hand',
              remoteId: 'workspace-a'),
          NStackWorkspace(
              id: 'removed-alias', name: 'Old', remoteId: 'workspace-old'),
        ],
        settings: NStackBrowserSettings(bookmarks: [
          BrowserBookmark(title: 'Canopy', url: 'https://canopy.example')
        ]),
      ),
      makeActive: true,
    );
    final service = NStackWorkspaceDiscoveryService(
      registryStore: store,
      discovery: _SequenceDiscovery([
        [
          _discovered('workspace-a', 'Server Alpha', identity.npub),
          _discovered('workspace-b', 'Server Beta', identity.npub),
        ]
      ]),
    );
    final refreshed = await service.refresh(
        identityNpub: identity.npub, secret: secret, stackId: 'stack-internal');
    expect(refreshed.name, 'Manual label');
    expect(refreshed.workspaces.map((item) => item.remoteId),
        ['workspace-a', 'workspace-b']);
    expect(refreshed.workspaces.first.id, 'legacy-alias');
    expect(refreshed.settings.bookmarks.single.title, 'Canopy');

    final roundTrip = NStackRegistry.decode(
        jsonEncode((await store.load(identity.npub)).toJson()));
    expect(roundTrip?.stacks.single.workspaces.first.workspaceOwnerNpub,
        identity.npub);
    expect(roundTrip?.stacks.single.workspaceDiscovery?.stale, isFalse);
  });

  test(
      'adding another endpoint with the same Tower identity keeps one saved stack',
      () async {
    final store = NStackRegistryStore();
    final original = _discovered('workspace-a', 'Alpha', identity.npub);
    final discovered = NStackWorkspace(
      id: original.id,
      name: original.name,
      remoteId: original.remoteId,
      stableRemoteId: original.stableRemoteId,
      workspaceOwnerNpub: original.workspaceOwnerNpub,
      workspaceServiceNpub: original.workspaceServiceNpub,
      serviceNpub: identity.npub,
    );
    final service = NStackWorkspaceDiscoveryService(
        registryStore: store,
        discovery: _SequenceDiscovery([
          [discovered],
          [discovered]
        ]));
    final first = await service.add(
        identityNpub: identity.npub,
        secret: secret,
        address: 'https://first.example');
    await store.rename(identity.npub, first.id, 'Home NStack');
    final moved = await service.add(
        identityNpub: identity.npub,
        secret: secret,
        address: 'https://second.example');
    final restarted = await NStackRegistryStore().load(identity.npub);
    expect(restarted.stacks, hasLength(1));
    expect(moved.id, first.id);
    expect(moved.name, 'Home NStack');
    expect(moved.url, 'https://second.example');
    expect(moved.workspaces.single.id, first.workspaces.single.id);
  });

  test('linked legacy to PG transition retains the private workspace alias',
      () async {
    final other = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final store = NStackRegistryStore();
    await store.addOrUpdate(
      identity.npub,
      NStackEntry(
        id: 'stack-internal',
        name: 'Stack',
        url: 'https://stack.example',
        workspaces: [
          NStackWorkspace(
            id: 'origin-private-alias',
            name: 'Legacy',
            remoteId: 'legacy-linked',
            stableRemoteId: 'legacy-linked',
            workspaceOwnerNpub: identity.npub,
            workspaceServiceNpub: other.npub,
            directHttpsUrl: 'https://stack.example',
            serviceNpub: other.npub,
          ),
        ],
      ),
    );
    final service = NStackWorkspaceDiscoveryService(
      registryStore: store,
      discovery: _SequenceDiscovery([
        [
          NStackWorkspace(
            id: '',
            name: 'Flight Deck PG',
            remoteId: 'pg-linked',
            stableRemoteId: 'legacy-linked',
            workspaceOwnerNpub: identity.npub,
            workspaceServiceNpub: other.npub,
            directHttpsUrl: 'https://stack.example',
            serviceNpub: other.npub,
          ),
        ],
      ]),
    );

    final refreshed = await service.refresh(
      identityNpub: identity.npub,
      secret: secret,
      stackId: 'stack-internal',
    );

    expect(refreshed.workspaces.single.id, 'origin-private-alias');
    expect(refreshed.workspaces.single.remoteId, 'pg-linked');
    expect(refreshed.workspaces.single.stableRemoteId, 'legacy-linked');
  });

  test('identity switch keeps discovery registries and refreshes isolated',
      () async {
    final other = NostrCrypto.importIdentity(
        '0000000000000000000000000000000000000000000000000000000000000002');
    final store = NStackRegistryStore();
    final service = NStackWorkspaceDiscoveryService(
      registryStore: store,
      discovery: _SequenceDiscovery([
        [_discovered('workspace-a', 'Identity A', identity.npub)],
        [_discovered('workspace-b', 'Identity B', other.npub)],
        [_discovered('workspace-b2', 'Identity B refreshed', other.npub)],
      ]),
    );
    final stackA = await service.add(
        identityNpub: identity.npub,
        secret: secret,
        address: 'https://stack.example');
    final stackB = await service.add(
        identityNpub: other.npub,
        secret:
            '0000000000000000000000000000000000000000000000000000000000000002',
        address: 'https://stack.example');

    expect(
        (await store.load(identity.npub)).stacks.single.workspaces.single.name,
        'Identity A');
    expect((await store.load(other.npub)).stacks.single.workspaces.single.name,
        'Identity B');

    await service.refresh(
      identityNpub: other.npub,
      secret:
          '0000000000000000000000000000000000000000000000000000000000000002',
      stackId: stackB.id,
    );
    expect((await store.load(other.npub)).stacks.single.workspaces.single.name,
        'Identity B refreshed');
    expect((await store.load(identity.npub)).stacks.single.id, stackA.id);
    expect(
        (await store.load(identity.npub)).stacks.single.workspaces.single.name,
        'Identity A');
  });
}

Map<String, dynamic> _authorizationEvent(http.Request request) =>
    jsonDecode(utf8.decode(base64Decode(
            request.headers['authorization']!.substring('Nostr '.length))))
        as Map<String, dynamic>;

String? _tag(Map<String, dynamic> event, String name) {
  for (final raw in event['tags'] as List) {
    final tag = raw as List;
    if (tag.length == 2 && tag[0] == name) return tag[1] as String;
  }
  return null;
}

Map<String, dynamic> _workspace(String id, String name, String npub,
        {Map<String, dynamic> extra = const {}}) =>
    {
      'workspace_id': id,
      'workspace_owner_npub': npub,
      'workspace_service_npub': npub,
      'name': name,
      'direct_https_url': 'https://tower.example',
      'service_npub': npub,
      ...extra,
    };

Map<String, dynamic> _flightDeckWorkspace(
  String id,
  String label, {
  required String owner,
  required String workspaceService,
  required String towerService,
  required String role,
  String? v4WorkspaceId,
  Map<String, dynamic> extra = const {},
}) =>
    {
      'identity': {
        'workspace_id': id,
        'workspace_owner_npub': owner,
        'workspace_service_npub': workspaceService,
        'tower_service_npub': towerService,
        'app_npub': towerService,
      },
      'label': label,
      'tower_base_url': 'https://stack.example',
      'v4_workspace_id': v4WorkspaceId,
      'membership': {'role': role},
      ...extra,
    };

NStackWorkspace _discovered(String id, String name, String npub) =>
    NStackWorkspace(
      id: '',
      name: name,
      remoteId: id,
      workspaceOwnerNpub: npub,
      workspaceServiceNpub: npub,
      directHttpsUrl: 'https://tower.example',
      serviceNpub: npub,
    );

class _SequenceDiscovery implements NStackWorkspaceDiscovery {
  _SequenceDiscovery(this.results);
  final List<Object> results;

  @override
  Future<List<NStackWorkspace>> discover({
    required String address,
    required String identityNpub,
    required String secret,
  }) async {
    final result = results.removeAt(0);
    if (result is NStackWorkspaceDiscoveryException) throw result;
    return result as List<NStackWorkspace>;
  }
}
