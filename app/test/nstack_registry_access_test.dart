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

  test('opaque discovery is origin scoped and capability handles are documents',
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
    final handle = await service.createHandle(
      documentId: 'document-a',
      identity: identity,
      origin: 'https://app-a.example',
      stackId: a['id'] as String,
      workspaceId: workspace['id'] as String,
      capabilities: const ['workspace.read', 'storage.read'],
    );
    expect(handle['handle'], isNotEmpty);
    expect((handle['connection'] as Map)['url'], 'https://host.example');
    service.revokeDocument('document-a');
    expect(service.activeHandles, isEmpty);
    expect(
      () => service.revokeHandle(
        documentId: 'document-a',
        identity: identity,
        origin: 'https://app-a.example',
        handle: handle['handle'] as String,
      ),
      throwsA(isA<NStackException>()
          .having((error) => error.code, 'code', 'stale_handle')),
    );
  });

  test('listing before consent and unsupported capability fail closed',
      () async {
    const identity = 'npub-identity';
    final registry = NStackRegistryStore();
    await registry.addOrUpdate(identity, _stack('internal-a', 'Host'));
    final service = NStackAccessService(
        registryStore: registry, grantStore: NStackGrantStore());
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
    final stackId = (await service.listNStacks(identity, 'https://app.example'))
        .single['id'] as String;
    expect(
      () => service.createHandle(
        documentId: 'doc',
        identity: identity,
        origin: 'https://app.example',
        stackId: stackId,
        capabilities: const ['administrator'],
      ),
      throwsA(isA<NStackException>()
          .having((error) => error.code, 'code', 'unsupported_capability')),
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
      'listWorkspaces',
      'requestCapabilities',
      'revoke',
    ]) {
      expect(script, contains(method));
    }
    expect(script, contains('version: 1'));
    expect(script, isNot(contains('fetch(')));
    expect(script, isNot(contains('WebSocket')));
    expect(script, isNot(contains('nsec')));
  });
}

NStackEntry _stack(String id, String name) => NStackEntry(
      id: id,
      name: name,
      url: 'https://host.example',
      workspaces: const [
        NStackWorkspace(
            id: 'workspace-internal', name: 'Main', remoteId: 'workspace-1'),
      ],
    );
