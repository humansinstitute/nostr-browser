import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/browser/browser_bookmark_store.dart';
import 'package:wingman_app/src/features/nstack/nstack_access.dart';
import 'package:wingman_app/src/features/nstack/nstack_bridge_script.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('registry persists and safely copies legacy bookmarks once', () async {
    const identity = 'npub-identity';
    final preferences = SharedPreferencesAsync();
    final legacy = jsonEncode({
      'version': 1,
      'bookmarks': [
        {'title': 'Ambulando', 'url': 'https://ambulando.example/app'}
      ],
    });
    await preferences.setString(
        '${BrowserBookmarkStore.keyPrefix}$identity', legacy);
    final store = NStackRegistryStore(preferences: preferences);
    final stack = _stack('internal-a', 'Host');
    await store.addOrUpdate(identity, stack, makeActive: true, makeHost: true);
    final bookmarks =
        await BrowserBookmarkStore(preferences: preferences).load(identity);
    await store.migrateLegacyBrowserSettings(identity, bookmarks: bookmarks);

    final reloaded =
        await NStackRegistryStore(preferences: preferences).load(identity);
    expect(reloaded.hostStack?.name, 'Host');
    expect(reloaded.activeStack?.settings.bookmarks.single.title, 'Ambulando');
    expect(
        await preferences
            .getString('${BrowserBookmarkStore.keyPrefix}$identity'),
        legacy,
        reason: 'migration must retain the legacy record byte-for-byte');
  });

  test(
      'legacy host migrates once only when exactly one workspace is accessible',
      () async {
    const identity = 'npub-legacy-one';
    final legacy = NStackRegistry(
      revision: 4,
      hostStackId: 'legacy-host',
      stacks: [_backupStack('legacy-host', 'workspace-a', _workspaceA)],
    );
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      '${NStackRegistryStore.keyPrefix}$identity': jsonEncode(legacy.toJson()),
    });
    final migrated = await NStackRegistryStore().load(identity);
    expect(migrated.backupDestination?.stackId, 'legacy-host');
    expect(migrated.backupDestination?.workspaceRemoteId, _workspaceA);
    expect(migrated.backupDestinationMigrationVersion, 1);
  });

  test('ambiguous legacy host requires selection and is never retried silently',
      () async {
    const identity = 'npub-legacy-many';
    final stack = _backupStack('legacy-host', 'workspace-a', _workspaceA,
        extraWorkspace: const NStackWorkspace(
          id: 'workspace-b',
          name: 'Second',
          remoteId: _workspaceB,
          stableRemoteId: _workspaceB,
          workspaceOwnerNpub: _npub,
          workspaceServiceNpub: _npub,
          directHttpsUrl: 'https://tower.example',
          membershipRole: 'member',
        ));
    final legacy = NStackRegistry(
        revision: 2, hostStackId: 'legacy-host', stacks: [stack]);
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      '${NStackRegistryStore.keyPrefix}$identity': jsonEncode(legacy.toJson()),
    });
    final store = NStackRegistryStore();
    final migrated = await store.load(identity);
    expect(migrated.backupDestination, isNull);
    expect(migrated.backupDestinationMigrationVersion, 1);
    await store.addOrUpdate(
      identity,
      _backupStack('legacy-host', 'workspace-a', _workspaceA),
    );
    expect((await store.load(identity)).backupDestination, isNull,
        reason: 'a later single workspace must not become an implicit choice');
  });

  test('origin consent exposes aliases and safe connection descriptors only',
      () async {
    const identity = 'npub-identity';
    final registry = NStackRegistryStore();
    await registry.addOrUpdate(identity, _stack('internal-a', 'Host'),
        makeActive: true);
    final grants = NStackGrantStore();
    final service = NStackAccessService(
      registryStore: registry,
      grantStore: grants,
      clock: () => DateTime.utc(2026, 10, 19),
    );
    await service.disclose(
      identity: identity,
      origin: 'https://app-a.example/path',
      stackInternalIds: ['internal-a'],
      includeWorkspaces: true,
    );
    await service.disclose(
      identity: identity,
      origin: 'https://app-b.example',
      stackInternalIds: ['internal-a'],
      includeWorkspaces: true,
    );
    final a =
        (await service.listNStacks(identity, 'https://app-a.example')).single;
    final b =
        (await service.listNStacks(identity, 'https://app-b.example')).single;
    expect(a['id'], isNot(b['id']));
    final workspace = (await service.listWorkspaces(
      identity: identity,
      origin: 'https://app-a.example',
      stackId: a['id'] as String,
    ))
        .single;
    final connection = await service.getConnection(
      identity: identity,
      origin: 'https://app-a.example',
      stackId: a['id'] as String,
      workspaceId: workspace['id'] as String,
    );
    expect(connection['workspaceId'], 'workspace-1');
    expect(connection['workspaceOwnerNpub'], _npub);
    expect(connection['directHttpsUrl'], 'https://tower.example');
    expect(connection, isNot(contains('stableRemoteId')));
    expect(connection, isNot(contains('stable_remote_id')));
    expect(connection, isNot(contains('handle')));
    expect(connection, isNot(contains('capabilities')));
    service.revokeDocument('document-a');
  });

  test('listing before consent and revoked origin fail closed', () async {
    const identity = 'npub-identity';
    final registry = NStackRegistryStore();
    await registry.addOrUpdate(identity, _stack('internal-a', 'Host'));
    final service = NStackAccessService(
        registryStore: registry, grantStore: NStackGrantStore());
    expect(
      () => service.listNStacks('', 'https://app.example'),
      throwsA(isA<NStackException>()
          .having((error) => error.code, 'code', 'locked')),
    );
    expect(
      () => service.applyDiscoveryDecision(
        identity: identity,
        origin: 'https://app.example',
        approvedStackInternalIds: null,
        includeWorkspaces: true,
      ),
      throwsA(isA<NStackException>()
          .having((error) => error.code, 'code', 'consent_denied')),
    );
    expect(await service.grantStore.list(identity), isEmpty);
    expect(
      () => service.listNStacks(identity, 'https://app.example'),
      throwsA(isA<NStackException>()
          .having((error) => error.code, 'code', 'not_disclosed')),
    );
    await service.disclose(
      identity: identity,
      origin: 'https://app.example',
      stackInternalIds: const ['internal-a'],
      includeWorkspaces: false,
    );
    await service.revokeOrigin(identity, 'https://app.example');
    expect(
      () => service.listNStacks(identity, 'https://app.example'),
      throwsA(isA<NStackException>()
          .having((error) => error.code, 'code', 'not_disclosed')),
    );
  });

  test('bridge shape exposes v1 methods without inventory or transport', () {
    final script = nstackBridgeScript(
        documentId: 'document-secret', pageOrigin: 'https://app.example');
    for (final method in const [
      'requestDiscovery',
      'listNStacks',
      'getServiceCatalogue',
      'listWorkspaces',
      'getConnection',
      'requestCapabilities',
      'revoke',
    ]) {
      expect(script, contains(method));
    }
    expect(script, contains('version: 1'));
    expect(script, contains('window !== window.top'));
    expect(script, contains('location.origin'));
    expect(script, contains('documentId'));
    expect(script, contains('stale_handle'));
    expect(script, isNot(contains('fetch(')));
    expect(script, isNot(contains('WebSocket')));
    expect(script, isNot(contains('nsec')));
    expect(nstackDocumentStartBootstrapScript, contains('NStackReady'));
    expect(nstackDocumentStartBootstrapScript, contains('nstackready'));
  });

  test('page origins normalize to the exact browser location.origin', () {
    const cases = {
      'https://Canopy.Example/feed?tab=1#top': 'https://canopy.example',
      'https://app.example': 'https://app.example',
      'https://app.example:443/': 'https://app.example',
      'https://app.example:8443/x': 'https://app.example:8443',
      'http://localhost:5173/route?q#f': 'http://localhost:5173',
      'http://wingman.local/': 'http://wingman.local',
    };
    for (final entry in cases.entries) {
      expect(normalizeNStackOrigin(entry.key), entry.value, reason: entry.key);
    }
    expect(normalizeNStackOrigin('http://app.example/'), isEmpty);
    expect(normalizeNStackOrigin('https://user@app.example/'), isEmpty);
  });

  test('provider install guard matches the page origin for routed URLs', () {
    // The browser derives pageOrigin from the full document URL. The provider
    // only installs when it equals location.origin, so a serialized empty
    // query/fragment (`?#`) left Canopy with a never-ready stub.
    const pageUrl = 'https://canopy.example/settings?panel=nstack#connect';
    final script = nstackBridgeScript(
      documentId: 'document-secret',
      pageOrigin: normalizeNStackOrigin(pageUrl),
    );
    expect(
        script,
        contains(
            'location.origin !== ${jsonEncode('https://canopy.example')}'));
    expect(script, isNot(contains('canopy.example?')));
    expect(script, isNot(contains('canopy.example#')));
  });

  test('persisted grants keyed by a malformed origin resolve canonically',
      () async {
    const identity = 'npub-identity';
    final preferences = SharedPreferencesAsync();
    await preferences.setString(
      '${NStackGrantStore.keyPrefix}$identity',
      jsonEncode({
        'version': 1,
        'grants': [
          {
            'origin': 'https://canopy.example?#',
            'stack_ids': {'internal-a': 'alias-a'},
            'workspace_ids': <String, String>{},
            'updated_at': '2026-10-20T00:00:00.000Z',
          }
        ],
      }),
    );
    final grants = NStackGrantStore(preferences: preferences);
    final grant = await grants.find(identity, 'https://canopy.example/feed');
    expect(grant?.origin, 'https://canopy.example');
  });

  test('deprecated capability method rejects locally without dispatch', () {
    final provider = nstackBridgeScript(
        documentId: 'document-secret', pageOrigin: 'https://app.example');

    for (final script in [nstackDocumentStartBootstrapScript, provider]) {
      expect(script, contains('requestCapabilities: rejectCapabilities'));
      expect(script, contains("error.code = 'invalid_request'"));
      expect(script, contains('NStack capabilities are not supported'));
      expect(script, isNot(contains("callWhenReady('requestCapabilities'")));
      expect(script, isNot(contains("call('requestCapabilities'")));
      expect(script, isNot(contains('nstack.requestCapabilities')));
    }
    expect(provider, isNot(contains('createHandle')));
    expect(provider, isNot(contains('capabilityHandle')));
  });
}

const _npub = 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqnp7z5';

NStackEntry _stack(String id, String name) => NStackEntry(
      id: id,
      name: name,
      url: 'https://host.example',
      workspaces: const [
        NStackWorkspace(
          id: 'workspace-internal',
          name: 'Main',
          remoteId: 'workspace-1',
          stableRemoteId: 'legacy-workspace-1',
          workspaceOwnerNpub: _npub,
          workspaceServiceNpub: _npub,
          directHttpsUrl: 'https://tower.example',
        ),
      ],
      workspaceDiscovery: NStackWorkspaceDiscoveryStatus(
        lastAttemptAt: DateTime.utc(2026, 10, 19),
        lastSuccessAt: DateTime.utc(2026, 10, 19),
        stale: false,
      ),
    );

const _workspaceA = '11111111-1111-4111-8111-111111111111';
const _workspaceB = '22222222-2222-4222-8222-222222222222';

NStackEntry _backupStack(String stackId, String workspaceId, String remoteId,
        {NStackWorkspace? extraWorkspace}) =>
    NStackEntry(
      id: stackId,
      name: 'Legacy host',
      url: 'https://tower.example',
      workspaces: [
        NStackWorkspace(
          id: workspaceId,
          name: 'Main',
          remoteId: remoteId,
          stableRemoteId: remoteId,
          workspaceOwnerNpub: _npub,
          workspaceServiceNpub: _npub,
          directHttpsUrl: 'https://tower.example',
          membershipRole: 'owner',
        ),
        if (extraWorkspace != null) extraWorkspace,
      ],
    );
