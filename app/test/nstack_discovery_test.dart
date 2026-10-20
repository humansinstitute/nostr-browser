import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/nstack/nstack_discovery.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';

void main() {
  final now = DateTime.utc(2026, 10, 19, 12);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('fetches only canonical well-known path and accepts three services',
      () async {
    late Uri requested;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response(jsonEncode(_descriptor()), 200);
    });
    final catalogue = await NStackDiscoveryClient(
      client: client,
      clock: () => now,
    ).fetch('https://tower.example/');

    expect(
        requested.toString(), 'https://tower.example/.well-known/nstack.json');
    expect(catalogue.services.map((service) => service.id),
        ['tower', 'relay', 'blossom']);
    expect(catalogue.service('tower')!.actionable, isTrue);
    expect(catalogue.service('relay')!.endpoint, 'wss://relay.example');
  });

  test('accepts Tower-only partial and unavailable or unknown observations',
      () {
    final partial = _descriptor()
      ..['services'] = [
        _service('tower', 'tower', 'https://tower.example', 'available'),
      ];
    expect(
      validateNStackDescriptor(partial,
              configuredOrigin: 'https://tower.example', fetchedAt: now)
          .services
          .single
          .id,
      'tower',
    );

    final observed = _descriptor()
      ..['services'] = [
        _service('tower', 'tower', 'https://tower.example', 'available'),
        _service('relay', 'nostr_relay', 'wss://relay.example', 'unavailable'),
        _service('blossom', 'blossom', 'https://blossom.example', 'unknown'),
        _service(
            'future-search', 'search', 'https://search.example', 'unknown'),
      ];
    final catalogue = validateNStackDescriptor(observed,
        configuredOrigin: 'https://tower.example', fetchedAt: now);
    expect(catalogue.service('relay')!.availability,
        NStackServiceAvailability.unavailable);
    expect(catalogue.service('blossom')!.availability,
        NStackServiceAvailability.unknown);
    expect(catalogue.service('future-search')!.actionable, isFalse);
  });

  test('rejects malformed schema, unsafe origins, duplicates and extra data',
      () {
    final cases = <Map<String, dynamic>>[
      _descriptor()..['schema'] = 'wrong',
      _descriptor()..['schema_version'] = 2,
      _descriptor()
        ..['services'] = [
          _service(
              'tower', 'tower', 'https://user:pass@tower.example', 'available'),
        ],
      _descriptor()
        ..['services'] = [
          _service('tower', 'tower', 'https://tower.example/path', 'available'),
        ],
      _descriptor()
        ..['services'] = [
          _service('tower', 'tower', 'https://other.example', 'available'),
        ],
      _descriptor()
        ..['services'] = [
          _service('tower', 'tower', 'https://tower.example', 'available'),
          _service('tower', 'tower', 'https://tower.example', 'available'),
        ],
      _descriptor()..['credential'] = 'secret',
    ];
    for (final descriptor in cases) {
      expect(
        () => validateNStackDescriptor(descriptor,
            configuredOrigin: 'https://tower.example', fetchedAt: now),
        throwsA(isA<NStackDiscoveryException>()),
      );
    }
  });

  test('rejects oversized response and bounds network time', () async {
    final oversized = NStackDiscoveryClient(
      client: MockClient((_) async =>
          http.Response('x' * (nstackDescriptorMaxBytes + 1), 200)),
      clock: () => now,
    );
    expect(
      () => oversized.fetch('https://tower.example'),
      throwsA(isA<NStackDiscoveryException>()
          .having((error) => error.code, 'code', 'oversized')),
    );

    final timeout = NStackDiscoveryClient(
      client: MockClient((_) => Completer<http.Response>().future),
      clock: () => now,
      timeout: const Duration(milliseconds: 1),
    );
    expect(
      () => timeout.fetch('https://tower.example'),
      throwsA(isA<NStackDiscoveryException>()
          .having((error) => error.code, 'code', 'timeout')),
    );
  });

  testWidgets('times out a slow-drip body at the total fetch deadline',
      (tester) async {
    final body = utf8.encode(jsonEncode(_descriptor()));
    final chunks = List<List<int>>.generate(10, (index) {
      final start = body.length * index ~/ 10;
      final end = body.length * (index + 1) ~/ 10;
      return body.sublist(start, end);
    });
    var emittedChunks = 0;
    final client = MockClient.streaming((request, _) async {
      final controller = StreamController<List<int>>();
      late final Timer timer;
      timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
        if (emittedChunks < chunks.length) {
          controller.add(chunks[emittedChunks]);
          emittedChunks += 1;
        } else {
          timer.cancel();
          controller.close();
        }
      });
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        timer.cancel();
        controller.close();
      });
      return http.StreamedResponse(controller.stream, 200);
    });
    final fetch = NStackDiscoveryClient(
      client: client,
      clock: () => now,
      timeout: const Duration(milliseconds: 5),
    ).fetch('https://tower.example');
    final expectation = expectLater(
      fetch,
      throwsA(isA<NStackDiscoveryException>()
          .having((error) => error.code, 'code', 'timeout')),
    );

    await tester.pump(const Duration(milliseconds: 5));

    await expectation;
    expect(emittedChunks, greaterThan(0));
    expect(emittedChunks, lessThan(chunks.length));
  });

  test('refresh preserves last-known-good and first failure invents nothing',
      () async {
    const identity = 'identity';
    final store = NStackRegistryStore();
    await store.addOrUpdate(
      identity,
      const NStackEntry(
          id: 'with-lkg', name: 'With catalogue', url: 'https://tower.example'),
    );
    var fail = false;
    final client = MockClient((_) async {
      if (fail) throw Exception('offline');
      return http.Response(jsonEncode(_descriptor()), 200);
    });
    final discovery = NStackDiscoveryService(
      registryStore: store,
      client: NStackDiscoveryClient(client: client, clock: () => now),
      clock: () => now,
    );
    final good = await discovery.refresh(identity, 'with-lkg');
    expect(good.catalogueStatus?.catalogue?.services, isNotEmpty);
    fail = true;
    final stale = await discovery.refresh(identity, 'with-lkg');
    expect(stale.catalogueStatus?.errorCode, 'network_error');
    expect(stale.catalogueStatus?.catalogue?.services, isNotEmpty);

    await store.addOrUpdate(
      identity,
      const NStackEntry(
          id: 'first-failure',
          name: 'No catalogue',
          url: 'https://new.example'),
    );
    final empty = await discovery.refresh(identity, 'first-failure');
    expect(empty.catalogueStatus?.errorCode, 'network_error');
    expect(empty.catalogueStatus?.catalogue, isNull);
  });

  test('catalogue binds to the verified origin while retaining a base path',
      () async {
    const identity = 'identity';
    final store = NStackRegistryStore();
    await store.addOrUpdate(
      identity,
      const NStackEntry(
        id: 'base-path',
        name: 'Tower proxy',
        url: 'https://tower.example/base',
      ),
    );
    final discovery = NStackDiscoveryService(
      registryStore: store,
      client: NStackDiscoveryClient(
        client: MockClient(
            (_) async => http.Response(jsonEncode(_descriptor()), 200)),
        clock: () => now,
      ),
      clock: () => now,
    );

    final refreshed = await discovery.refresh(identity, 'base-path');

    expect(refreshed.url, 'https://tower.example/base');
    expect(refreshed.catalogueStatus?.catalogue?.service('tower')?.endpoint,
        'https://tower.example');
  });

  test('v1 registry migrates to v2 while retaining legacy bytes', () async {
    const identity = 'identity';
    final preferences = SharedPreferencesAsync();
    final legacy = jsonEncode({
      'schema': 'org.wingman.nbrowser.nstack-registry',
      'version': 1,
      'revision': 4,
      'active_stack_id': 'legacy',
      'host_stack_id': null,
      'stacks': [
        {
          'id': 'legacy',
          'name': 'Legacy',
          'url': 'https://legacy.example',
          'fips_endpoint': null,
          'peer_npub': null,
          'workspaces': [],
          'settings': const NStackBrowserSettings().toJson(),
        }
      ],
    });
    await preferences.setString(
        '${NStackRegistryStore.legacyKeyPrefix}$identity', legacy);
    final migrated =
        await NStackRegistryStore(preferences: preferences).load(identity);
    expect(migrated.version, nstackRegistryVersion);
    expect(migrated.activeStack?.name, 'Legacy');
    expect(
        await preferences
            .getString('${NStackRegistryStore.legacyKeyPrefix}$identity'),
        legacy);
    final v2 = await preferences
        .getString('${NStackRegistryStore.keyPrefix}$identity');
    expect(jsonDecode(v2!)['version'], nstackRegistryVersion);
  });
}

Map<String, dynamic> _descriptor() => {
      'schema': 'org.wingman.nstack.services',
      'schema_version': 1,
      'generated_at': '2026-10-19T12:00:00.000Z',
      'cache_ttl_seconds': 30,
      'stack': {
        'tower_npub': 'npub1${List.filled(58, 'q').join()}',
        'name': 'Example stack',
      },
      'services': [
        _service('tower', 'tower', 'https://tower.example', 'available'),
        _service('relay', 'nostr_relay', 'wss://relay.example', 'available'),
        _service('blossom', 'blossom', 'https://blossom.example', 'available'),
      ],
    };

Map<String, dynamic> _service(
        String id, String kind, String endpoint, String availability) =>
    {
      'id': id,
      'kind': kind,
      'endpoint': endpoint,
      'version': '1.0.0',
      'protocols': switch (id) {
        'tower' => ['https', 'nip-98'],
        'relay' => ['nostr-relay'],
        'blossom' => ['blossom'],
        _ => ['https'],
      },
      'capabilities': switch (id) {
        'tower' => [
            'workspace.authenticated_discovery',
            'records.sync',
            'storage.private',
            'flightdeck.pg',
          ],
        'relay' => ['events.publish', 'events.query', 'events.subscribe'],
        'blossom' => ['blob.get', 'blob.upload'],
        _ => ['search.query'],
      },
      'features': {
        'nips': id == 'relay' || id == 'tower' ? [1, 98] : <int>[],
        'buds': id == 'blossom' ? [1, 2, 11] : <int>[],
      },
      'availability': {
        'status': availability,
        'checked_at':
            availability == 'unknown' ? null : '2026-10-19T12:00:00.000Z',
      },
    };
